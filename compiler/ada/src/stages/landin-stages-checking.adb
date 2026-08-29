with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;

with Landin.Checking;
with Landin.Diagnostics.Checking;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Source;
with Landin.Stages.Checking.Flow;
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
   use type Landin.Targets.Bit_Width;
   use type Landin.Targets.Byte_Count;
   use type Landin.Types.Type_Kind;
   use type Landin.Types.Folded;
   use type Landin.Types.Magnitude;
   use type Landin.Checking.Progress;
   use type Landin.Checking.Element_Count;
   use type Landin.Checking.Field_Kind;
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

      --  Which declaration a declaring node is.  Resolution publishes the
      --  other direction, so the few stage-level callers scan the short,
      --  source-ordered declaration table.
      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
         return Res.Declaration_Id;

      function Declaration_At
        (Src : Landin.Source.Source_Id; Node : Syn.Node_Id)
         return Res.Declaration_Id
      is
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
      function Is_Local_Binding
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Construction_Body
        (Of_Tree : Syn.Tree; Literal : Syn.Node_Id)
         return Res.Declaration_Id;
      function Construction_Agrees
        (Of_Tree  : Syn.Tree;
         Literal  : Syn.Node_Id;
         Expected : Res.Declaration_Id;
         Related  : Landin.Provenance.Origin;
         Because  : String) return Boolean;
      function Declared_As_Node
        (Of_Tree         : Syn.Tree;
         Node            : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration)
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
      function Selected_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;
      function Admit_Array_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
      function Admit_Variant_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;
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
        (Of_Tree        : Syn.Tree;
         Node           : Syn.Node_Id;
         Stepping       : Boolean;
         Variant_Context : Boolean := False);
      procedure Check_Array_Literal
        (Of_Tree      : Syn.Tree;
         Context      : Syn.Node_Id;
         Literal      : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean);
      procedure Check_Struct_Literal
        (Of_Tree      : Syn.Tree;
         Literal      : Syn.Node_Id;
         Wrote        : Res.Declaration_Id;
         Static_Image : Boolean);
      procedure Check_Variant_Value
        (Of_Tree : Syn.Tree;
         Site    : Syn.Node_Id;
         Value   : Syn.Node_Id;
         Wrote   : Res.Declaration_Id;
         Field   : Positive;
         Static_Image : Boolean := False);
      procedure Check_Match
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind);
      procedure Check_Mixed_Array_Repetition
        (Of_Tree      : Syn.Tree;
         Site_Node    : Syn.Node_Id;
         Repetition   : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean);
      procedure Check_Array_Repetition
        (Of_Tree      : Syn.Tree;
         Site_Node    : Syn.Node_Id;
         Repetition   : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean);
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
               function Total_Cases return Natural;
               function Total_Payload_Fields return Natural;

               function Total_Cases return Natural is
                  Total : Natural := 0;
               begin
                  for Index in 1 .. Syn.Field_Count (Of_Tree, Written) loop
                     declare
                        Member : constant Syn.Node_Id :=
                          Syn.Nth_Field (Of_Tree, Written, Index);
                     begin
                        if Syn.Kind (Of_Tree, Member) = Syn.Variant_Part then
                           Total := Total + Syn.Case_Count
                             (Of_Tree, Member);
                        end if;
                     end;
                  end loop;
                  return Total;
               end Total_Cases;

               function Total_Payload_Fields return Natural is
                  Total : Natural := 0;
               begin
                  for Index in 1 .. Syn.Field_Count (Of_Tree, Written) loop
                     declare
                        Member : constant Syn.Node_Id :=
                          Syn.Nth_Field (Of_Tree, Written, Index);
                     begin
                        if Syn.Kind (Of_Tree, Member) = Syn.Variant_Part then
                           for Which in 1 .. Syn.Case_Count
                             (Of_Tree, Member)
                           loop
                              Total := Total + Syn.Payload_Field_Count
                                (Of_Tree,
                                 Syn.Nth_Case (Of_Tree, Member, Which));
                           end loop;
                        end if;
                     end;
                  end loop;
                  return Total;
               end Total_Payload_Fields;

               Fields : Landin.Checking.Field_Shape_Array
                 (1 .. Syn.Field_Count (Of_Tree, Written)) :=
                   [others => (Kind    => Landin.Checking.Scalar_Field,
                               Element => Ty.U8,
                               Length  => 1,
                               others  => <>)];
               Cases : Landin.Checking.Case_Run_Array
                 (1 .. Total_Cases) := [others => (others => 0)];
               Payloads : Landin.Checking.Field_Shape_Array
                 (1 .. Total_Payload_Fields) :=
                   [others => (Kind    => Landin.Checking.Scalar_Field,
                               Element => Ty.U8,
                               Length  => 1,
                               others  => <>)];
               Can_Lay_Out : Boolean := True;
               Next_Case : Natural := 1;
               Next_Payload : Natural := 1;

               procedure Check_Leaf
                 (Each : Syn.Node_Id;
                  Into : out Landin.Checking.Field_Shape;
                  Aggregate_Allowed : Boolean);

               procedure Check_Leaf
                 (Each : Syn.Node_Id;
                  Into : out Landin.Checking.Field_Shape;
                  Aggregate_Allowed : Boolean)
               is
                  Held : constant Ty.Type_Kind :=
                    Type_At (Of_Tree, Syn.Declared_Type (Of_Tree, Each));
               begin
                  Into := (Kind    => Landin.Checking.Scalar_Field,
                           Element => Ty.U8,
                           Length  => 1,
                           others  => <>);
                  if Held in Ty.Scalar_Name then
                     Into :=
                       (Kind    => Landin.Checking.Scalar_Field,
                        Element => Ty.Scalar_Name (Held),
                        Length  => 1,
                        others  => <>);
                  elsif Held = Ty.Fixed_Array then
                     Into :=
                       (Kind    => Landin.Checking.Fixed_Array_Field,
                        Element => Landin.Checking.Array_Element
                                     (Types.all, Of_Tree,
                                      Syn.Declared_Type (Of_Tree, Each)),
                        Length  => Landin.Checking.Array_Length
                                     (Types.all, Of_Tree,
                                      Syn.Declared_Type (Of_Tree, Each)),
                        others  => <>);
                  elsif Held = Ty.Aggregate
                    and then Aggregate_Allowed
                  then
                     declare
                        Child_Body : constant Res.Declaration_Id :=
                          Landin.Checking.Body_Of
                            (Types.all, Of_Tree,
                             Syn.Declared_Type (Of_Tree, Each));
                     begin
                        if Child_Body /= Res.No_Declaration
                          and then Landin.Checking.Has_Layout
                            (Types.all, Child_Body)
                          and then not Landin.Checking.Has_Variant_Part
                            (Types.all, Child_Body)
                          and then not Landin.Checking.Has_Aggregate_Field
                            (Types.all, Child_Body)
                        then
                           Into :=
                             (Kind    => Landin.Checking.Aggregate_Field,
                              Element => Ty.Bool,
                              Length  => 1,
                              Aggregate_Body => Child_Body,
                              others  => <>);
                        else
                           Can_Lay_Out := False;
                        end if;
                     end;
                  else
                     Can_Lay_Out := False;
                  end if;

                  if Held = Ty.Aggregate
                    and then Into.Kind /= Landin.Checking.Aggregate_Field
                  then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Each),
                        Message => "a field of a struct type is not"
                                   & " enabled yet",
                        Refused => Bad.Struct_Value,
                        Into    => Found);
                  end if;
               end Check_Leaf;
            begin
               for Index in 1 .. Syn.Field_Count (Of_Tree, Written) loop
                  declare
                     Each : constant Syn.Node_Id :=
                       Syn.Nth_Field (Of_Tree, Written, Index);
                  begin
                     if Syn.Kind (Of_Tree, Each) = Syn.Field then
                        Check_Leaf (Each, Fields (Index), True);
                     else
                        declare
                           Count : constant Natural :=
                             Syn.Case_Count (Of_Tree, Each);
                           Tag : constant Ty.Scalar_Name :=
                             (if Count <= 2 ** 8 then Ty.U8
                              elsif Count <= 2 ** 16 then Ty.U16
                              else Ty.U32);
                        begin
                           Fields (Index) :=
                             (Kind           => Landin.Checking.Variant_Field,
                              Element        => Tag,
                              Length         => 1,
                              Cases          => Count,
                              Payloads_First => Next_Case,
                              others         => <>);

                           for Which in 1 .. Count loop
                              declare
                                 Variant : constant Syn.Node_Id :=
                                   Syn.Nth_Case
                                     (Of_Tree, Each, Which);
                                 Payload_Count : constant Natural :=
                                   Syn.Payload_Field_Count
                                     (Of_Tree, Variant);
                              begin
                                 Cases (Next_Case) :=
                                   (First =>
                                      (if Payload_Count = 0
                                       then 0 else Next_Payload),
                                    Count => Payload_Count);
                                 Next_Case := Next_Case + 1;

                                 for Position in 1 .. Payload_Count loop
                                    Check_Leaf
                                      (Syn.Nth_Payload_Field
                                         (Of_Tree, Variant, Position),
                                       Payloads (Next_Payload), False);
                                    Next_Payload := Next_Payload + 1;
                                 end loop;
                              end;
                           end loop;
                        end;
                     end if;
                  end;
               end loop;

               if Can_Lay_Out then
                  if For_Declaration = Res.No_Declaration then
                     raise Landin.Compiler_Defect with
                       "a struct body has no declaration identity";
                  end if;

                  declare
                     Fits : Boolean;
                  begin
                     Landin.Checking.Lay_Out
                       (Types.all, For_Declaration, Fields, Facts, Fits,
                        Cases => Cases, Payloads => Payloads);

                     if not Fits then
                        Bad.Report
                          (Item    => Bad.Literal_Out_Of_Range,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Written),
                           Message => "this struct is too large for the"
                                      & " target's usize",
                           Note    => "D45: every padded aggregate extent"
                                      & " must fit the selected target",
                           Into    => Found);
                     end if;
                  end;
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

      --  D72: construction is a Struct_Literal whose optional nominal slot
      --  is a type position.  It supplies [0710]'s body to an inferred
      --  binding and must agree with a typed binding or assignment place.
      --  The literal itself remembers a failed callee so later contextual
      --  passes decline to add a second report.
      function Construction_Body
        (Of_Tree : Syn.Tree; Literal : Syn.Node_Id)
         return Res.Declaration_Id
      is
         Nominal : constant Syn.Node_Id :=
           Syn.Constructed_Type (Of_Tree, Literal);
      begin
         if Nominal = Syn.No_Node
           or else Landin.Checking.Type_Of (Types.all, Of_Tree, Literal)
                     = Ty.Ill_Typed
         then
            return Res.No_Declaration;
         end if;

         --  A resolved binding or function in this position is a permanent
         --  construction error, not a deferred call-shaped value feature.
         if Syn.Kind (Of_Tree, Nominal) = Syn.Type_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Nominal)
                      = Res.Bound
           and then Res.Sort_Of
             (Meanings.all,
              Res.Bound_To (Meanings.all, Of_Tree, Nominal))
                = Res.Case_Name
         then
            Bad.Report
              (Item    => Bad.Unsupported_Use,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Nominal),
               Message => "a variant case cannot be constructed until"
                          & " variant values are enabled",
               Refused => Bad.Variant_Value,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            return Res.No_Declaration;
         end if;

         if Syn.Kind (Of_Tree, Nominal) = Syn.Type_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Nominal)
                      = Res.Bound
           and then Res.Sort_Of
             (Meanings.all,
              Res.Bound_To (Meanings.all, Of_Tree, Nominal))
                /= Res.Module_Type
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Nominal),
               Message => "this name is not a type, so it cannot construct"
                          & " a struct",
               Note    => "[0700]: construction applies a type to labelled"
                          & " field values",
               Related => Syn.Origin (Of_Tree, Literal),
               Because => "this construction",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            return Res.No_Declaration;
         end if;

         declare
            Held : constant Ty.Type_Kind := Type_At (Of_Tree, Nominal);
         begin
            if Held = Ty.Aggregate then
               declare
                  Wrote : constant Res.Declaration_Id :=
                    Landin.Checking.Body_Of (Types.all, Of_Tree, Nominal);
               begin
                  if Landin.Checking.Has_Layout (Types.all, Wrote)
                    and then Landin.Checking.Has_Aggregate_Field
                      (Types.all, Wrote)
                  then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Nominal),
                        Message => "a nested-struct value is not enabled"
                                   & " yet",
                        Refused => Bad.Struct_Value,
                        Into    => Found);
                     Landin.Checking.Refuse
                       (Types.all, Of_Tree, Literal);
                     return Res.No_Declaration;
                  end if;
                  return Wrote;
               end;
            elsif Held = Ty.Ill_Typed then
               --  Type_At either reported the missing/refused type or
               --  inherited its earlier owner.  Mark the enclosing value so
               --  module recovery does not walk the failed type a second
               --  time.
               Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            else
               Bad.Report
                 (Item    => Bad.Type_Mismatch,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Nominal),
                  Message => "this is not an ordinary struct type",
                  Note    => "[0700]: construction applies a struct type to"
                             & " labelled field values",
                  Related => Syn.Origin (Of_Tree, Literal),
                  Because => "this construction",
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            end if;

            return Res.No_Declaration;
         end;
      end Construction_Body;

      function Construction_Agrees
        (Of_Tree  : Syn.Tree;
         Literal  : Syn.Node_Id;
         Expected : Res.Declaration_Id;
         Related  : Landin.Provenance.Origin;
         Because  : String) return Boolean
      is
         Nominal : constant Syn.Node_Id :=
           Syn.Constructed_Type (Of_Tree, Literal);
         Wrote : Res.Declaration_Id;
      begin
         if Nominal = Syn.No_Node then
            return True;
         end if;

         Wrote := Construction_Body (Of_Tree, Literal);
         if Wrote = Res.No_Declaration then
            return False;
         elsif Wrote /= Expected then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Nominal),
               Message => "this constructs a different struct type",
               Note    => "[0710]: two structs are one type when one"
                          & " declaration wrote both, and never otherwise",
               Related => Related,
               Because => Because,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            return False;
         end if;

         return True;
      end Construction_Agrees;

      function Is_Local_Binding
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean is
      begin
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id
                        (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Source_Of (Meanings.all, Id) = Syn.Source_Of (Of_Tree)
              and then Res.Node_Of (Meanings.all, Id) = Node
            then
               return Res.Sort_Of (Meanings.all, Id) = Res.Local_Binding;
            end if;
         end loop;

         return False;
      end Is_Local_Binding;

      function Declared_As_Node
        (Of_Tree         : Syn.Tree;
         Node            : Syn.Node_Id;
         For_Declaration : Res.Declaration_Id := Res.No_Declaration)
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
            Struct_Body_Id : constant Res.Declaration_Id :=
              (if Held = Ty.Aggregate
               then Landin.Checking.Body_Of
                 (Types.all, Of_Tree, Written)
               else Res.No_Declaration);
            Variant_Bearing : constant Boolean :=
              Struct_Body_Id /= Res.No_Declaration
              and then Landin.Checking.Has_Layout
                (Types.all, Struct_Body_Id)
              and then Landin.Checking.Has_Variant_Part
                (Types.all, Struct_Body_Id);
            Aggregate_Bearing : constant Boolean :=
              Struct_Body_Id /= Res.No_Declaration
              and then Landin.Checking.Has_Layout
                (Types.all, Struct_Body_Id)
              and then Landin.Checking.Has_Aggregate_Field
                (Types.all, Struct_Body_Id);
            --  D46 admits [1740]'s declaration-only module state once D45
            --  laid out all of its scalar and fixed-array fields: D10 makes
            --  the entire datum zero without forming an aggregate value.
            --  D47 admits the same declaration-only shape as one frame cell;
            --  D16 still tracks and requires its scalar fields independently.
            --  A parameter, return or written value still needs a whole-value
            --  rule this slice does not have.
            Is_Aggregate_Parameter : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Parameter;
            Is_Aggregate_Return : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Named_Return;
            Is_Array_Parameter : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Parameter;
            Is_Array_Return : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Named_Return;
            Is_Zeroed_State : constant Boolean :=
              Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) = Syn.No_Node
              --  A name, or an array written where the type belongs.
              --  [0710]'s identity is a declaration, so an anonymous
              --  struct body declares none and cannot be state; D17
              --  makes an array's identity its shape, which `[3]usize`
              --  carries wherever it is written.
              and then Syn.Kind (Of_Tree, Written)
                       in Syn.Type_Reference | Syn.Array_Type
              and then
                (Held /= Ty.Aggregate
                 or else
                   Landin.Checking.Body_Of
                     (Types.all, Of_Tree, Written) /= Res.No_Declaration);
            --  D21: an array binding may be initialized directly from a
            --  whole-array storage name.  Resolution makes that module
            --  storage at module scope and an in-scope storage declaration
            --  inside a body.  D51 also admits a fixed-array field when the
            --  destination binding is local; D70 admits the same contextual
            --  source for a module binding's static image.  The field remains
            --  outside the general-value rules.  Every other
            --  value form (an array literal, a call, `zeroed`, or a slice) is
            --  deferred: none of them is a Name_Reference.  An inferred
            --  direct-name binding has no Written node and is admitted
            --  separately by Infer.
            Is_Direct_Name_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then
                ((Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                    = Syn.Name_Reference
                  and then Res.Verdict_Of
                    (Meanings.all, Of_Tree, Syn.Value_Of (Of_Tree, Node))
                      = Res.Bound
                  and then Res.Sort_Of
                    (Meanings.all,
                     Res.Bound_To
                       (Meanings.all, Of_Tree,
                        Syn.Value_Of (Of_Tree, Node)))
                      in Res.Module_Binding | Res.Local_Binding)
                 or else
                   (Syn.Kind
                      (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                        = Syn.Member_Selection
                    and then Syn.Kind
                      (Of_Tree,
                       Syn.Target_Of
                         (Of_Tree, Syn.Value_Of (Of_Tree, Node)))
                        = Syn.Name_Reference
                    and then Res.Verdict_Of
                      (Meanings.all, Of_Tree,
                       Syn.Target_Of
                         (Of_Tree, Syn.Value_Of (Of_Tree, Node)))
                        = Res.Bound
                    and then Res.Sort_Of
                      (Meanings.all,
                       Res.Bound_To
                         (Meanings.all, Of_Tree,
                          Syn.Target_Of
                            (Of_Tree, Syn.Value_Of (Of_Tree, Node))))
                        in Res.Module_Binding | Res.Local_Binding)
                 or else
                   (Is_Local_Binding (Of_Tree, Node)
                    and then Syn.Kind
                      (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                        = Syn.Member_Selection
                    and then Syn.Kind
                      (Of_Tree,
                       Syn.Target_Of
                         (Of_Tree, Syn.Value_Of (Of_Tree, Node)))
                        = Syn.Member_Selection
                    and then Syn.Kind
                      (Of_Tree,
                       Syn.Target_Of
                         (Of_Tree,
                          Syn.Target_Of
                            (Of_Tree, Syn.Value_Of (Of_Tree, Node))))
                        = Syn.Name_Reference));
            --  D55/D60: a written local or module struct type supplies the
            --  nominal context for one initializer copied directly from
            --  storage.  The module form copies a static image rather than
            --  executing a runtime copy.
            --  Resolution has already stopped the pipeline for an unresolved
            --  name; a resolved type declaration is not runtime storage.
            Is_Direct_Struct_Init : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then
                ((Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                    = Syn.Name_Reference
                  and then Res.Verdict_Of
                    (Meanings.all, Of_Tree, Syn.Value_Of (Of_Tree, Node))
                      = Res.Bound
                  and then Res.Sort_Of
                    (Meanings.all,
                     Res.Bound_To
                       (Meanings.all, Of_Tree,
                        Syn.Value_Of (Of_Tree, Node)))
                      in Res.Module_Binding | Res.Local_Binding)
                 or else
                   (Is_Local_Binding (Of_Tree, Node)
                    and then Syn.Kind
                      (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                        = Syn.Member_Selection
                    and then Syn.Kind
                      (Of_Tree,
                       Syn.Target_Of
                         (Of_Tree, Syn.Value_Of (Of_Tree, Node)))
                        = Syn.Name_Reference
                    and then Res.Verdict_Of
                      (Meanings.all, Of_Tree,
                       Syn.Target_Of
                         (Of_Tree, Syn.Value_Of (Of_Tree, Node)))
                        = Res.Bound))
              and then Landin.Checking.Body_Of
                (Types.all, Of_Tree, Written) /= Res.No_Declaration;
            Is_Array_Call_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Call;
            Is_Struct_Call_Init : constant Boolean :=
              Held = Ty.Aggregate
              and then Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Call
              and then Landin.Checking.Body_Of
                (Types.all, Of_Tree, Written) /= Res.No_Declaration;
            --  D57/D59: the written local or module struct supplies [0540]'s
            --  complete all-bits-zero image.  Inference and general values
            --  remain separate contextual positions.
            Is_Struct_Zeroed_Init : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Zeroed_Literal
              and then Landin.Checking.Body_Of
                (Types.all, Of_Tree, Written) /= Res.No_Declaration;
            --  D64/D66: a written local or module struct type supplies the
            --  body for one labelled literal.  The module form is a static
            --  image; an inferred literal still has no nominal identity.
            Is_Struct_Literal_Init : constant Boolean :=
              Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Struct_Literal
              and then Landin.Checking.Body_Of
                (Types.all, Of_Tree, Written) /= Res.No_Declaration;
            --  D23 admits a literal only where its written local array type
            --  supplies both the element context and the exact length.
            Is_Local_Literal_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Array_Literal;
            --  D24 admits the same literal as a module binding's static
            --  image, on the same terms: the written type supplies the
            --  exact length and the scalar context.  Every element must
            --  also be [1940]'s "known", which Check_Module_Value asks
            --  once the checker settles the types.
            --  D34 admits full-array repetition where a written nonzero array
            --  type supplies its shape, for either module or local storage.
            --  D33/D35's inferred local and module forms are admitted by Infer
            --  before this written-declaration gate.
            Is_Typed_Repetition_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Written /= Syn.No_Node
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Array_Repetition;
            --  D36/D38 admit a mixed prefix for an explicitly typed local or
            --  module array; inferred and general-value forms remain refused.
            Is_Typed_Mixed_Repetition_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Written /= Syn.No_Node
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Mixed_Array_Repetition;
            Is_Module_Literal_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then not Is_Local_Binding (Of_Tree, Node)
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Array_Literal;
            --  D27: every scalar element this kernel admits has one all-zero
            --  image, so an explicitly typed module array can use [0540]
            --  without recording a per-position static image.
            Is_Module_Zeroed_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then not Is_Local_Binding (Of_Tree, Node)
              and then Written /= Syn.No_Node
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Zeroed_Literal;
            --  D28 uses the same contextual image for an explicitly typed
            --  local, whose complete compact frame slot lowering clears at
            --  runtime rather than enumerating D18's target-sized extent.
            Is_Local_Zeroed_Init : constant Boolean :=
              Held = Ty.Fixed_Array
              and then Syn.Kind (Of_Tree, Node) = Syn.Binding
              and then Is_Local_Binding (Of_Tree, Node)
              and then Written /= Syn.No_Node
              and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                       = Syn.Zeroed_Literal;
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
              and then not Is_Local_Literal_Init
              and then not Is_Typed_Repetition_Init
              and then not Is_Typed_Mixed_Repetition_Init
              and then not Is_Module_Literal_Init
              and then not Is_Module_Zeroed_Init
              and then not Is_Local_Zeroed_Init
              and then not Is_Array_Call_Init
              and then not Is_Array_Parameter
              and then not Is_Array_Return
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
                     Message =>
                       (if Syn.Kind (Of_Tree, Node) = Syn.Binding
                           and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
                           and then Syn.Kind
                                      (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                                    = Syn.Zeroed_Literal
                        then "`zeroed` is not enabled for a local array"
                        else "a value of an array type is not enabled yet"),
                     Refused =>
                       (if Syn.Kind (Of_Tree, Node) = Syn.Binding
                           and then Syn.Value_Of (Of_Tree, Node) /= Syn.No_Node
                           and then Syn.Kind
                                      (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                                    = Syn.Zeroed_Literal
                        then Bad.Zeroed_Value
                        else Bad.Array_Value),
                     Into    => Found);
               end if;

               return Ty.Ill_Typed;
            end if;

            if Held = Ty.Aggregate
              and then Aggregate_Bearing
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
              and then not Is_Struct_Zeroed_Init
              and then not Is_Struct_Call_Init
              and then not Is_Aggregate_Parameter
              and then not Is_Aggregate_Return
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
                     Message => "a nonzero value of a nested-struct type is"
                                & " not enabled yet",
                     Refused =>
                       (if Syn.Kind (Of_Tree, Node)
                              in Syn.Parameter | Syn.Named_Return
                        then Bad.Struct_ABI
                        else Bad.Struct_Value),
                     Into    => Found);
               end if;
               return Ty.Ill_Typed;
            end if;

            if Held = Ty.Aggregate
              and then Variant_Bearing
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
              and then not Is_Struct_Zeroed_Init
              and then not Is_Struct_Literal_Init
              and then not Is_Direct_Struct_Init
              and then not Is_Struct_Call_Init
              and then not Is_Aggregate_Parameter
              and then not Is_Aggregate_Return
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
                     Message => "this value of a variant-bearing struct is"
                                & " not enabled yet",
                     Refused =>
                       (if Syn.Kind (Of_Tree, Node)
                              in Syn.Parameter | Syn.Named_Return
                        then Bad.Struct_ABI
                        else Bad.Variant_Value),
                     Into    => Found);
               end if;
               return Ty.Ill_Typed;
            end if;

            if Held = Ty.Aggregate
              and then Syn.Kind (Of_Tree, Node) /= Syn.Type_Declaration
              and then not Is_Zeroed_State
              and then not Is_Direct_Struct_Init
              and then not Is_Struct_Call_Init
              and then not Is_Struct_Zeroed_Init
              and then not Is_Struct_Literal_Init
              and then not Is_Aggregate_Parameter
              and then not Is_Aggregate_Return
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
                     Refused =>
                       (if Syn.Kind (Of_Tree, Node)
                              in Syn.Parameter | Syn.Named_Return
                        then Bad.Struct_ABI
                        else Bad.Struct_Value),
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
               --  A Parameter or a Named_Return keeps its former refusal
               --  path because it is not a Binding node.
               Held : constant Ty.Type_Kind :=
                 Declared_As_Node
                   (Of_Tree.all, Node,
                    (if Is_Body then Id else Res.No_Declaration));
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
               Argument : constant Syn.Node_Id :=
                 Syn.Nth_Argument (Of_Tree, Node, Which);
            begin
               if Wants = Ty.Aggregate
                 and then Syn.Kind (Of_Tree, Argument) = Syn.Struct_Literal
               then
                  declare
                     Expected : constant Res.Declaration_Id :=
                       Landin.Checking.Body_Of
                         (Types.all, Their_Tree.all,
                          Syn.Declared_Type (Their_Tree.all, Parameter));
                     Leaf_Only : Boolean := True;
                  begin
                     for Field in
                       1 .. Landin.Checking.Layout_Field_Count
                              (Types.all, Expected)
                     loop
                        Leaf_Only := Leaf_Only
                          and then Landin.Checking.Field_Kind_Of
                            (Types.all, Expected, Field)
                              in Landin.Checking.Scalar_Field
                                 | Landin.Checking.Fixed_Array_Field
                                 | Landin.Checking.Aggregate_Field
                                 | Landin.Checking.Variant_Field;
                     end loop;

                     if Leaf_Only
                       and then Construction_Agrees
                         (Of_Tree, Argument, Expected,
                          Syn.Origin (Their_Tree.all, Parameter),
                          "this parameter")
                     then
                        Check_Struct_Literal
                          (Of_Tree, Argument, Expected,
                           Static_Image => False);
                     else
                        Require
                          (Of_Tree, Argument, Wants,
                           Syn.Origin (Their_Tree.all, Parameter),
                           "this parameter");
                     end if;
                  end;
               elsif Wants = Ty.Fixed_Array
                 and then Syn.Kind (Of_Tree, Argument)
                            in Syn.Array_Literal | Syn.Array_Repetition
                               | Syn.Mixed_Array_Repetition
               then
                  declare
                     Expected : constant Landin.Checking.Element_Count :=
                       Landin.Checking.Array_Length
                         (Types.all, Their_Tree.all,
                          Syn.Declared_Type (Their_Tree.all, Parameter));
                     Element : constant Ty.Scalar_Name :=
                       Landin.Checking.Array_Element
                         (Types.all, Their_Tree.all,
                          Syn.Declared_Type (Their_Tree.all, Parameter));
                  begin
                     case Syn.Kind (Of_Tree, Argument) is
                        when Syn.Array_Literal =>
                           Check_Array_Literal
                             (Of_Tree, Parameter, Argument,
                              Expected, Element, Static_Image => False);
                        when Syn.Array_Repetition =>
                           Check_Array_Repetition
                             (Of_Tree, Parameter, Argument,
                              Expected, Element, Static_Image => False);
                        when Syn.Mixed_Array_Repetition =>
                           Check_Mixed_Array_Repetition
                             (Of_Tree, Parameter, Argument,
                              Expected, Element, Static_Image => False);
                        when others =>
                           raise Landin.Compiler_Defect;
                     end case;
                  end;
               elsif Wants in Ty.Aggregate | Ty.Fixed_Array
                 and then Syn.Kind (Of_Tree, Argument) = Syn.Zeroed_Literal
               then
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Argument, Wants);
                  if Wants = Ty.Aggregate then
                     Landin.Checking.Note_Body
                       (Types.all, Of_Tree, Argument,
                        Landin.Checking.Body_Of
                          (Types.all, Their_Tree.all,
                           Syn.Declared_Type
                             (Their_Tree.all, Parameter)));
                  else
                     Landin.Checking.Note_Array
                       (Types.all, Of_Tree, Argument,
                        Landin.Checking.Array_Length
                          (Types.all, Their_Tree.all,
                           Syn.Declared_Type
                             (Their_Tree.all, Parameter)),
                        Landin.Checking.Array_Element
                          (Types.all, Their_Tree.all,
                           Syn.Declared_Type
                             (Their_Tree.all, Parameter)));
                  end if;
               elsif Wants in Ty.Aggregate | Ty.Fixed_Array
                 and then Syn.Kind (Of_Tree, Argument)
                            in Syn.Name_Reference | Syn.Member_Selection
                 and then
                   (Syn.Kind (Of_Tree, Argument) = Syn.Name_Reference
                    or else Wants = Ty.Fixed_Array
                    or else Syn.Kind
                      (Of_Tree, Syn.Target_Of (Of_Tree, Argument))
                        = Syn.Name_Reference)
               then
                  declare
                     Got : constant Ty.Type_Kind :=
                       (if Wants = Ty.Fixed_Array
                           and then Syn.Kind (Of_Tree, Argument)
                                      = Syn.Member_Selection
                        then (if Admit_Array_Field (Of_Tree, Argument)
                              then Ty.Fixed_Array else Ty.Ill_Typed)
                        else Selected_From (Of_Tree, Argument));
                     Expected : constant Res.Declaration_Id :=
                       Landin.Checking.Body_Of
                         (Types.all, Their_Tree.all,
                          Syn.Declared_Type (Their_Tree.all, Parameter));
                     Actual : constant Res.Declaration_Id :=
                       Landin.Checking.Body_Of
                         (Types.all, Of_Tree, Argument);
                  begin
                     if Got = Ty.Aggregate and then Actual /= Expected then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Argument);
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Argument),
                           Message => "this argument has a different struct"
                                      & " type",
                           Note    => "[0710]: ordinary structs are nominal",
                           Related => Syn.Origin
                             (Their_Tree.all, Parameter),
                           Because => "this parameter",
                           Into    => Found);
                     elsif Got = Ty.Fixed_Array
                       and then
                         (Landin.Checking.Array_Length
                            (Types.all, Of_Tree, Argument)
                            /= Landin.Checking.Array_Length
                                 (Types.all, Their_Tree.all,
                                  Syn.Declared_Type
                                    (Their_Tree.all, Parameter))
                          or else Landin.Checking.Array_Element
                            (Types.all, Of_Tree, Argument)
                            /= Landin.Checking.Array_Element
                                 (Types.all, Their_Tree.all,
                                  Syn.Declared_Type
                                    (Their_Tree.all, Parameter)))
                     then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Argument);
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Argument),
                           Message => "this argument has a different array"
                                      & " shape",
                           Note    => "D17: a fixed array is its length and"
                                      & " scalar element type",
                           Related => Syn.Origin
                             (Their_Tree.all, Parameter),
                           Because => "this parameter",
                           Into    => Found);
                     elsif Got /= Wants then
                        Require
                          (Of_Tree, Argument, Wants,
                           Syn.Origin (Their_Tree.all, Parameter),
                           "this parameter");
                     end if;
                  end;
               else
                  Require
                    (Of_Tree, Argument, Wants,
                     Syn.Origin (Their_Tree.all, Parameter),
                     "this parameter");
               end if;
            end;
         end loop;

         if Result = Syn.No_Node then
            return Ty.No_Value;
         end if;

         declare
            Gives : constant Ty.Type_Kind :=
              Declared_As_Node (Their_Tree.all, Result);
         begin
            if Gives = Ty.Aggregate then
               Landin.Checking.Note_Body
                 (Types.all, Of_Tree, Node,
                  Landin.Checking.Body_Of
                    (Types.all, Their_Tree.all,
                     Syn.Declared_Type (Their_Tree.all, Result)));
            elsif Gives = Ty.Fixed_Array then
               Landin.Checking.Note_Array
                 (Types.all, Of_Tree, Node,
                  Landin.Checking.Array_Length
                    (Types.all, Their_Tree.all,
                     Syn.Declared_Type (Their_Tree.all, Result)),
                  Landin.Checking.Array_Element
                    (Types.all, Their_Tree.all,
                     Syn.Declared_Type (Their_Tree.all, Result)));
            end if;
            return Gives;
         end;
      end Check_Call;

      --  [1950]'s third row.  An index the compiler knows is refused when
      --  it is outside the length, and one it does not know is left to the
      --  trap the backend emits -- which is what the divisor and the shift
      --  amount already do, in the same paragraph and for the same reason.
      --  Known is [1880]'s: a literal, or a unary minus over one.
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
      --  D48 first admits a fixed-array field in the one context that names
      --  one of its elements.  Keeping this separate from Selected_From
      --  leaves the field itself refused as a general value or place while
      --  D49/D50 add two assignment contexts explicitly.
      function Indexed_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind;

      function Is_Direct_Module_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Module_Array_Field
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Length  : Landin.Checking.Element_Count;
         Element : Ty.Scalar_Name) return Boolean;

      --  D49/D50 admit that same fixed-array field as a whole place only
      --  when assignment supplies `zeroed` or another fixed-array storage
      --  endpoint as its complete contextual value.  D51 reuses the note for
      --  a local initializer source; the local/module gates remain at those
      --  contextual callers.
      --  This predicate notes the field shape when that exact place exists;
      --  it reports nothing and leaves every other selection for the
      --  ordinary place checker, so root mutability and field diagnostics
      --  keep their existing ownership.
      function Is_Direct_Array_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Selected_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind is
      begin
         --  D88 admits a depth-one ordinary child only as the base of a
         --  further field selection.  Synthesise still refuses the child as
         --  a general aggregate value; this path-bearing question records
         --  both declaration-order identities and the child's nominal body.
         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection then
            declare
               From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
               Held : constant Ty.Type_Kind := Selected_From (Of_Tree, From);
            begin
               if Held = Ty.Aggregate then
                  declare
                     Wrote : constant Res.Declaration_Id :=
                       Landin.Checking.Body_Of (Types.all, Of_Tree, From);
                     Which : constant Natural :=
                       (if Wrote = Res.No_Declaration then 0
                        else Field_At (Wrote, Syn.Name (Of_Tree, Node)));
                  begin
                     if Which > 0
                       and then Landin.Checking.Has_Layout (Types.all, Wrote)
                       and then Landin.Checking.Field_Kind_Of
                                  (Types.all, Wrote, Which)
                                = Landin.Checking.Aggregate_Field
                     then
                        declare
                           Child : constant Res.Declaration_Id :=
                             Landin.Checking.Field_Shape_Of
                               (Types.all, Wrote, Which).Aggregate_Body;
                        begin
                           if Landin.Checking.Type_Of
                                (Types.all, Of_Tree, Node) = Ty.Undecided
                           then
                              Landin.Checking.Note
                                (Types.all, Of_Tree, Node, Ty.Aggregate);
                              Landin.Checking.Note_Field
                                (Types.all, Of_Tree, Node, Which);
                              Landin.Checking.Note_Body
                                (Types.all, Of_Tree, Node, Child);
                           end if;
                           return Ty.Aggregate;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;

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
               if Held = Ty.Ill_Typed then
                  return Held;
               end if;

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

      function Admit_Array_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              = Ty.Fixed_Array
         then
            return True;
         end if;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
              /= Ty.Undecided
         then
            return False;
         end if;

         if Syn.Kind (Of_Tree, Node) = Syn.Member_Selection then
            declare
               From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
               Direct : constant Boolean :=
                 Syn.Kind (Of_Tree, From) = Syn.Name_Reference;
               Depth_One : constant Boolean :=
                 Syn.Kind (Of_Tree, From) = Syn.Member_Selection
                 and then Syn.Kind
                   (Of_Tree, Syn.Target_Of (Of_Tree, From))
                     = Syn.Name_Reference;
            begin
               if Direct or else Depth_One then
                  declare
                     Held : constant Ty.Type_Kind :=
                       Selected_From (Of_Tree, From);
                  begin
                     if Held = Ty.Ill_Typed then
                        return False;
                     end if;

                     if Held = Ty.Aggregate then
                        declare
                           Wrote : constant Res.Declaration_Id :=
                             Landin.Checking.Body_Of
                               (Types.all, Of_Tree, From);
                           Which : constant Natural :=
                             (if Wrote = Res.No_Declaration then 0
                              else Field_At
                                     (Wrote, Syn.Name (Of_Tree, Node)));
                        begin
                           if Which /= 0
                             and then Landin.Checking.Has_Layout
                                        (Types.all, Wrote)
                             and then Landin.Checking.Field_Kind_Of
                                        (Types.all, Wrote, Which)
                                      = Landin.Checking.Fixed_Array_Field
                           then
                              Landin.Checking.Note
                                (Types.all, Of_Tree, Node, Ty.Fixed_Array);
                              Landin.Checking.Note_Field
                                (Types.all, Of_Tree, Node, Which);
                              Landin.Checking.Note_Array
                                (Types.all, Of_Tree, Node,
                                 Landin.Checking.Field_Array_Length
                                   (Types.all, Wrote, Which),
                                 Landin.Checking.Field_Array_Element
                                   (Types.all, Wrote, Which));
                              return True;
                           end if;
                        end;
                     end if;
                  end;
               end if;
            end;
         end if;

         return False;
      end Admit_Array_Field;

      function Admit_Variant_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         if Syn.Kind (Of_Tree, Node) /= Syn.Member_Selection then
            return False;
         end if;

         declare
            From : constant Syn.Node_Id := Syn.Target_Of (Of_Tree, Node);
         begin
            if Syn.Kind (Of_Tree, From) /= Syn.Name_Reference
              or else Res.Verdict_Of (Meanings.all, Of_Tree, From)
                        /= Res.Bound
            then
               return False;
            end if;

            declare
               Held : constant Ty.Type_Kind := Selected_From (Of_Tree, From);
            begin
               if Held /= Ty.Aggregate then
                  return False;
               end if;

               declare
                  Wrote : constant Res.Declaration_Id :=
                    Landin.Checking.Body_Of (Types.all, Of_Tree, From);
                  Which : constant Natural :=
                    (if Wrote = Res.No_Declaration then 0
                     else Field_At (Wrote, Syn.Name (Of_Tree, Node)));
               begin
                  if Which = 0
                    or else not Landin.Checking.Has_Layout (Types.all, Wrote)
                    or else Landin.Checking.Field_Kind_Of
                      (Types.all, Wrote, Which)
                        /= Landin.Checking.Variant_Field
                  then
                     return False;
                  end if;

                  if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                       = Ty.Undecided
                  then
                     --  A variant part is a contextual destination, not a
                     --  general aggregate value.  Not_Typed records that
                     --  distinction while allowing Check_Place and lowering
                     --  to share the resolved field identity.
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Node, Ty.Not_Typed);
                     Landin.Checking.Note_Field
                       (Types.all, Of_Tree, Node, Which);
                  end if;
                  return True;
               end;
            end;
         end;
      end Admit_Variant_Field;

      function Is_Direct_Module_Field
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         return Syn.Kind (Of_Tree, Node) = Syn.Member_Selection
           and then Syn.Kind
             (Of_Tree, Syn.Target_Of (Of_Tree, Node)) = Syn.Name_Reference
           and then Res.Verdict_Of
             (Meanings.all, Of_Tree, Syn.Target_Of (Of_Tree, Node))
               = Res.Bound
           and then Res.Sort_Of
             (Meanings.all,
              Res.Bound_To
                (Meanings.all, Of_Tree, Syn.Target_Of (Of_Tree, Node)))
               = Res.Module_Binding;
      end Is_Direct_Module_Field;

      function Is_Module_Array_Field
        (Of_Tree : Syn.Tree;
         Node    : Syn.Node_Id;
         Length  : Landin.Checking.Element_Count;
         Element : Ty.Scalar_Name) return Boolean
      is
      begin
         return Is_Direct_Module_Field (Of_Tree, Node)
           and then Admit_Array_Field (Of_Tree, Node)
           and then Landin.Checking.Array_Length
             (Types.all, Of_Tree, Node) = Length
           and then Landin.Checking.Array_Element
             (Types.all, Of_Tree, Node) = Element;
      end Is_Module_Array_Field;

      function Indexed_From
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Ty.Type_Kind
      is
      begin
         if Admit_Array_Field (Of_Tree, Node) then
            return Ty.Fixed_Array;
         end if;

         return Selected_From (Of_Tree, Node);
      end Indexed_From;

      --  D21's inferred array initializer is deliberately narrower than an
      --  inferred value: it recognizes only a resolved direct storage name.
      --  Keeping that question here prevents Selected_From from admitting a
      --  struct name, or any expression that merely produces an array.
      function Is_Direct_Array_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         return Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
           and then Res.Sort_Of
                      (Meanings.all,
                       Res.Bound_To (Meanings.all, Of_Tree, Node))
                    in Res.Module_Binding | Res.Local_Binding
           and then Settled_Type
                      (Res.Bound_To (Meanings.all, Of_Tree, Node))
                    = Ty.Fixed_Array;
      end Is_Direct_Array_Name;

      --  Whether this node directly names a binding that owns runtime storage.
      function Is_Direct_Binding_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Direct_Binding_Name
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
      begin
         return Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
           and then Res.Sort_Of
                      (Meanings.all,
                       Res.Bound_To (Meanings.all, Of_Tree, Node))
                    in Res.Module_Binding | Res.Local_Binding;
      end Is_Direct_Binding_Name;

      --  D41 is a direct-binding slice; D42 adds one ordinary scalar field or
      --  fixed-array element selected immediately from that storage.  D62
      --  adds the scalar element of a D48 fixed-array field.  D43 adds a
      --  direct named return, but not one of its subobjects.  D85 lets an
      --  indexed fixed-array match alias supply the same scalar context.
      --  Every other nested subobject remains a separate contextual position.
      function Is_Zeroed_Scalar_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean;

      function Is_Zeroed_Scalar_Place
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id) return Boolean
      is
         Is_Direct_Named_Return : constant Boolean :=
           Syn.Kind (Of_Tree, Node) = Syn.Name_Reference
           and then Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound
           and then Res.Sort_Of
                      (Meanings.all,
                       Res.Bound_To (Meanings.all, Of_Tree, Node))
                    = Res.Named_Return;
      begin
         return Is_Direct_Binding_Name (Of_Tree, Node)
           or else Is_Direct_Named_Return
           or else
             (Syn.Kind (Of_Tree, Node)
                in Syn.Member_Selection | Syn.Element_Index
              and then Is_Direct_Binding_Name
                         (Of_Tree, Syn.Target_Of (Of_Tree, Node)))
           or else
             (Syn.Kind (Of_Tree, Node) = Syn.Element_Index
              and then Syn.Kind
                (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                  = Syn.Member_Selection
              and then Is_Direct_Binding_Name
                (Of_Tree,
                 Syn.Target_Of
                   (Of_Tree, Syn.Target_Of (Of_Tree, Node))))
           or else
             (Syn.Kind (Of_Tree, Node) = Syn.Element_Index
              and then Syn.Kind
                (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                  = Syn.Name_Reference
              and then Res.Verdict_Of
                (Meanings.all, Of_Tree, Syn.Target_Of (Of_Tree, Node))
                  = Res.Bound
              and then Res.Sort_Of
                (Meanings.all,
                 Res.Bound_To
                   (Meanings.all, Of_Tree,
                    Syn.Target_Of (Of_Tree, Node)))
                  = Res.Pattern_Binding);
      end Is_Zeroed_Scalar_Place;

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

            when Syn.Zeroed_Literal =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "`zeroed` needs a directly supplied initializer"
                             & " or assignment type",
                  Refused => Bad.Zeroed_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            --  D14: a measurement is a `usize`.  The type it asks about
            --  is recorded on its own node, because the lowering reads it
            --  from there and a type name is not an expression that would
            --  otherwise be walked.
            when Syn.Size_Of | Syn.Align_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Measured_Type (Of_Tree, Node);
               begin
                  --  D14, D17 and D44: legality follows the resolved checked
                  --  type, not the syntax that happened to spell it.  Type_At
                  --  also carries an array's structural shape or a struct's
                  --  nominal body onto this node, including through aliases.
                  declare
                     Held : constant Ty.Type_Kind := Type_At (Of_Tree, Asked);
                  begin
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Asked) = Ty.Undecided
                     then
                        Landin.Checking.Note
                          (Types.all, Of_Tree, Asked, Held);
                     end if;

                     if Held in Ty.Scalar_Name | Ty.Fixed_Array
                       or else
                         (Held = Ty.Aggregate
                          and then Landin.Checking.Body_Of
                            (Types.all, Of_Tree, Asked)
                              /= Res.No_Declaration
                          and then Landin.Checking.Has_Layout
                            (Types.all,
                             Landin.Checking.Body_Of
                               (Types.all, Of_Tree, Asked)))
                     then
                        return Kept (Ty.Usize);
                     end if;

                     --  Type_At already reported the field that prevented a
                     --  complete layout, including D45's padded-size limit.
                     --  The measurement adds no second diagnosis.
                     if Held = Ty.Aggregate then
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  An unresolved or malformed type was already named by
                     --  its owning stage.  In particular, do not add a second
                     --  measurement report for it.
                     if Held = Ty.Ill_Typed then
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  Type_At answers one of the admitted shapes above or
                     --  Ill_Typed after its owning diagnostic.  Anything
                     --  else is compiler state, not a source refusal.
                     raise Landin.Compiler_Defect with
                       "a measured type has no settled checked shape";
                  end;
               end;

            --  [0370]: the length belongs to a named fixed-array type or to
            --  the source shape of D31's nonempty literal.  Neither form reads
            --  storage or evaluates a literal element.
            when Syn.Len_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
               begin
                  if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal then
                     declare
                        Count : constant Landin.Checking.Element_Count :=
                          Landin.Checking.Element_Count
                            (Syn.Element_Count (Of_Tree, Asked));
                        First : constant Syn.Node_Id :=
                          Syn.Nth_Element (Of_Tree, Asked, 1);
                        Got : constant Ty.Type_Kind :=
                          Synthesise (Of_Tree, First);
                        Element : Ty.Scalar_Name;
                     begin
                        if Got = Ty.Untyped_Integer then
                           Element := Ty.Default_Integer;
                           Commit_To (Of_Tree, First, Element);
                        elsif Got in Ty.Scalar_Name then
                           Element := Ty.Scalar_Name (Got);
                        else
                           if Got = Ty.No_Value then
                              Bad.Report
                                (Item    => Bad.Type_Mismatch,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, First),
                                 Message => "this hands back nothing, so it"
                                            & " cannot supply an array"
                                            & " element type",
                                 Note    => "D31: `lenof` checks one scalar"
                                            & " element type without"
                                            & " evaluating the elements",
                                 Related => Syn.Origin (Of_Tree, Asked),
                                 Because => "this measured literal",
                                 Into    => Found);
                           elsif Got /= Ty.Ill_Typed then
                              Bad.Report
                                (Item    => Bad.Type_Mismatch,
                                 Source  => Syn.Source_Of (Of_Tree),
                                 Where   => Syn.Where (Of_Tree, First),
                                 Message => "this is " & Shown (Got)
                                            & ", and an array literal needs"
                                            & " a scalar element type",
                                 Note    => "D31: `lenof` checks the literal's"
                                            & " D25 scalar shape",
                                 Related => Syn.Origin (Of_Tree, Asked),
                                 Because => "this measured literal",
                                 Into    => Found);
                           end if;

                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Asked);
                           return Kept (Ty.Ill_Typed);
                        end if;

                        Landin.Checking.Note
                          (Types.all, Of_Tree, Asked, Ty.Fixed_Array);
                        Landin.Checking.Note_Array
                          (Types.all, Of_Tree, Asked, Count, Element);

                        for Position in
                          2 .. Syn.Element_Count (Of_Tree, Asked)
                        loop
                           Require
                             (Of_Tree,
                              Syn.Nth_Element
                                (Of_Tree, Asked, Position),
                              Element, Syn.Origin (Of_Tree, Asked),
                              "the first literal element measured by `lenof`");
                        end loop;

                        return Kept (Ty.Usize);
                     end;
                  end if;

                  declare
                     Held : constant Ty.Type_Kind :=
                       Selected_From (Of_Tree, Asked);
                  begin
                     if Held = Ty.Ill_Typed then
                        --  In particular, an unresolved name was already
                        --  reported and remains resolution-owned.
                        return Kept (Ty.Ill_Typed);
                     end if;

                     if Held /= Ty.Fixed_Array then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Asked),
                           Message => "this is not a fixed array, so it has no"
                                      & " array length",
                           Note    => "[0370]: this kernel's `lenof` measures"
                                      & " a named array or array literal",
                           Related => Syn.Origin (Of_Tree, Asked),
                           Because => "what it names",
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;
                  end;

                  return Kept (Ty.Usize);
               end;

            when Syn.Array_Literal =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "an array literal needs a fixed-array binding"
                             & " or assignment context",
                  Refused => Bad.Array_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            when Syn.Struct_Literal =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "a struct literal needs an explicitly typed"
                             & " initializer or whole assignment",
                  Refused => Bad.Struct_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            when Syn.Array_Repetition =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "array repetition needs a typed binding, a"
                             & " counted inferred binding, or assignment",
                  Refused => Bad.Array_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            when Syn.Mixed_Array_Repetition =>
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Node),
                  Message => "mixed-prefix array repetition needs an"
                             & " explicitly typed local initializer",
                  Refused => Bad.Array_Value,
                  Into    => Found);
               return Kept (Ty.Ill_Typed);

            when Syn.Name_Reference =>
               if Res.Verdict_Of (Meanings.all, Of_Tree, Node)
                  /= Res.Bound
               then
                  return Kept (Ty.Ill_Typed);
               end if;

               declare
                  Means : constant Res.Declaration_Id :=
                    Res.Bound_To (Meanings.all, Of_Tree, Node);
               begin
                  if Res.Sort_Of (Meanings.all, Means) = Res.Case_Name then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Node),
                        Message => "a variant case used as a value is not"
                                   & " enabled yet",
                        Refused => Bad.Variant_Value,
                        Into    => Found);
                     return Kept (Ty.Ill_Typed);
                  end if;

                  declare
                     Held : constant Ty.Type_Kind := Settled_Type (Means);
                  begin
                     --  [1920]: a function's name anywhere but in front of a
                     --  `(` is a function value [1000], which [1790]'s type
                     --  rule does not spell.
                     if Held = Ty.Not_Typed then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "`"
                                      & Spelled (Syn.Name (Of_Tree, Node))
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
                           Message => "`"
                                      & Spelled (Syn.Name (Of_Tree, Node))
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
                           Message => "`"
                                      & Spelled (Syn.Name (Of_Tree, Node))
                                      & "` names an array, and a value of one"
                                      & " is not enabled yet",
                           Refused => Bad.Array_Value,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     return Kept (Held);
                  end;
               end;

            when Syn.Element_Index =>
               declare
                  From : constant Syn.Node_Id :=
                    Syn.Target_Of (Of_Tree, Node);
                  Where : constant Syn.Node_Id := Syn.Index_Of (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Indexed_From (Of_Tree, From);
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

                     --  D46/D47 admit direct containing storage, D48 admits
                     --  its element through Indexed_From, and D89 does the
                     --  same through one ordinary child. The field by itself
                     --  is still not a value or whole place. Refuse it before
                     --  Field_Type's scalar precondition.
                     if Landin.Checking.Field_Kind_Of
                          (Types.all, Wrote, Which)
                          = Landin.Checking.Fixed_Array_Field
                     then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "a fixed-array field is not an enabled"
                                      & " value or nested place yet",
                           Refused => Bad.Array_Value,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  D75 carries the complete variant part in storage and
                     --  clears it as one zero image.  Its tag and payload are
                     --  not scalar fields: D76/D77 own construction and
                     --  matching, so a direct selection remains one refused
                     --  value/place instead of reaching Field_Type's scalar
                     --  precondition.
                     if Landin.Checking.Field_Kind_Of
                          (Types.all, Wrote, Which)
                          = Landin.Checking.Variant_Field
                     then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "a variant part cannot be selected as"
                                      & " a value or place yet",
                           Refused => Bad.Variant_Value,
                           Into    => Found);
                        return Kept (Ty.Ill_Typed);
                     end if;

                     --  D88 admits scalar leaves only through a further
                     --  selection.  The intermediate ordinary child remains
                     --  no general value or whole place, so keep this direct
                     --  occurrence away from the scalar accessor.
                     if Landin.Checking.Field_Kind_Of
                          (Types.all, Wrote, Which)
                          = Landin.Checking.Aggregate_Field
                     then
                        Bad.Report
                          (Item    => Bad.Unsupported_Use,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Node),
                           Message => "a nested struct field is not an"
                                      & " enabled value or place yet",
                           Refused => Bad.Struct_Value,
                           Into    => Found);
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
        (Of_Tree        : Syn.Tree;
         Node           : Syn.Node_Id;
         Stepping       : Boolean;
         Variant_Context : Boolean := False)
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
                  when Res.Module_Type | Res.Case_Name => False,
                  when Res.Pattern_Binding =>
                     Syn.Is_Mutable (Their_Tree.all, Their_Node),
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

            if Variant_Context then
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

      --  D24/D66: a static image may fold scalar syntax but may not read a
      --  selected runtime place or carry a nested array value.  Keep this
      --  recursive refusal shared by array and struct image contexts so a
      --  construct hidden under an operator has one owner and one report.
      procedure Refuse_Static_Image_Subtree
        (Of_Tree : Syn.Tree; Where : Syn.Node_Id; Context : String);

      procedure Refuse_Static_Image_Subtree
        (Of_Tree : Syn.Tree; Where : Syn.Node_Id; Context : String)
      is
         What : constant String :=
           (case Syn.Kind (Of_Tree, Where) is
               when Syn.Member_Selection => "a field selection",
               when Syn.Element_Index    => "an array index",
               when Syn.Array_Literal    => "a nested array literal",
               when others               => "");
      begin
         if What /= "" then
            Bad.Report
              (Item    => Bad.Unsupported_Use,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Where),
               Message => What & " is not enabled as " & Context,
               Refused => Bad.Array_Value,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Where);
            --  Stop walking a refused subtree so an operator above it does
            --  not multiply the same report.
            return;
         end if;

         for Slot in 1 .. Syn.Slot_Count (Of_Tree, Where) loop
            Refuse_Static_Image_Subtree
              (Of_Tree, Syn.Slot (Of_Tree, Where, Slot), Context);
         end loop;
      end Refuse_Static_Image_Subtree;

      procedure Check_Array_Literal
        (Of_Tree      : Syn.Tree;
         Context      : Syn.Node_Id;
         Literal      : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean)
      is
      begin
         --  Check_Module_Value refuses a call element by [1940] and marks
         --  the whole literal Ill_Typed on the way out; walking each
         --  element still catches the shape and the scalar context, but
         --  the second Note on the literal itself would repeat what the
         --  first report already said.
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Literal)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Literal, Ty.Fixed_Array);
            Landin.Checking.Note_Array
              (Types.all, Of_Tree, Literal, Expected, Element);
         end if;

         if Landin.Checking.Element_Count
              (Syn.Element_Count (Of_Tree, Literal)) /= Expected
         then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Literal),
               Message => "this literal has "
                          & Counted
                              (Syn.Element_Count (Of_Tree, Literal), "element")
                          & ", and its array context has a different length",
               Note    => "D23/D24/D26/D29: an array literal supplies exactly"
                          & " the number of elements its context names",
               Related => Syn.Origin (Of_Tree, Context),
               Because => "the array context here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
         end if;

         for Position in 1 .. Syn.Element_Count (Of_Tree, Literal) loop
            Require
              (Of_Tree, Syn.Nth_Element (Of_Tree, Literal, Position), Element,
               Syn.Origin (Of_Tree, Context), "the array element type");
         end loop;

         --  D24: an element must be a compile-time known scalar the
         --  target-aware fold can compute; that admits every [1820]
         --  operator applied to literals and to another module scalar
         --  binding, and it excludes a member selection, an array
         --  element index and a nested array literal.  A call has been
         --  refused above by [1940] and reports L0305; these three are
         --  refused here so the reader sees a boundary rather than a
         --  compiler defect during image resolution.  The walk is
         --  recursive because a subtree hides the same construct: `p.x
         --  + 1` and `source[0] & 0xFF` reach the fold as an Add and a
         --  Bitwise_And whose top-level kind is admitted, and only the
         --  subtree carries the refusal.  A runtime literal (D23/D29)
         --  accepts every well-typed expression and does not run this walk.
         if Static_Image then
            for Position in 1 .. Syn.Element_Count (Of_Tree, Literal) loop
               Refuse_Static_Image_Subtree
                 (Of_Tree,
                  Syn.Nth_Element (Of_Tree, Literal, Position),
                  "a module array literal element");
            end loop;
         end if;
      end Check_Array_Literal;

      --  D76: a case value is contextual to one variant part.  A bare case
      --  selects an empty payload; a case construction labels each scalar
      --  payload leaf, while a fixed-array leaf may take only its zero image
      --  in this first executable slice.  The value and its labels retain
      --  source-order identities for lowering without becoming general
      --  aggregate values.
      procedure Check_Variant_Value
        (Of_Tree : Syn.Tree;
         Site    : Syn.Node_Id;
         Value   : Syn.Node_Id;
         Wrote   : Res.Declaration_Id;
         Field   : Positive;
         Static_Image : Boolean := False)
      is
         Body_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Wrote));
         Body_Node : constant Syn.Node_Id :=
           Syn.Declared_Type
             (Body_Tree.all, Res.Node_Of (Meanings.all, Wrote));
         Part : constant Syn.Node_Id :=
           Syn.Nth_Field (Body_Tree.all, Body_Node, Field);
         Nominal : Syn.Node_Id := Syn.No_Node;
         Means : Res.Declaration_Id := Res.No_Declaration;
         Which : Natural := 0;
         Failed : Boolean := False;

         function Subtree_Was_Refused
           (Node : Syn.Node_Id) return Boolean;

         procedure Check_Fixed_Array_Payload
           (Label : Syn.Node_Id;
            Given : Syn.Node_Id;
            Shape : Landin.Checking.Field_Shape);

         function Subtree_Was_Refused
           (Node : Syn.Node_Id) return Boolean
         is
         begin
            if Node = Syn.No_Node then
               return False;
            elsif Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                    = Ty.Ill_Typed
            then
               return True;
            end if;

            for Slot in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
               if Subtree_Was_Refused
                    (Syn.Slot (Of_Tree, Node, Slot))
               then
                  return True;
               end if;
            end loop;
            return False;
         end Subtree_Was_Refused;

         procedure Check_Fixed_Array_Payload
           (Label : Syn.Node_Id;
            Given : Syn.Node_Id;
            Shape : Landin.Checking.Field_Shape)
         is
            procedure Require_Known (Each : Syn.Node_Id);

            procedure Require_Known (Each : Syn.Node_Id) is
            begin
               if not Subtree_Was_Refused (Each)
                 and then not Is_Known (Of_Tree, Each)
               then
                  Bad.Report
                    (Item    => Bad.Not_Known_At_Compile_Time,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Each),
                     Message => "this variant payload image value has to be"
                                & " known when the module image is formed",
                     Note    => "[1940]: nothing runs before the entry"
                                & " point [1460]",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Each);
               end if;
            end Require_Known;
         begin
            pragma Assert (Shape.Kind = Landin.Checking.Fixed_Array_Field);

            --  D82/D83 reuse D67--D71's static image forms inside D81's
            --  selected payload descriptor run.  D84 gives runtime case
            --  construction D65's same contextual array-destination forms.
            --  Only the static branch asks [1940] to fold its expressions.
            case Syn.Kind (Of_Tree, Given) is
               when Syn.Array_Literal =>
                  Check_Array_Literal
                    (Of_Tree, Label, Given, Shape.Length, Shape.Element,
                     Static_Image => Static_Image);
                  if Static_Image then
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Given)
                     loop
                        Require_Known
                          (Syn.Nth_Element (Of_Tree, Given, Position));
                     end loop;
                  end if;

               when Syn.Array_Repetition =>
                  Check_Array_Repetition
                    (Of_Tree, Label, Given, Shape.Length, Shape.Element,
                     Static_Image => Static_Image);
                  if Static_Image then
                     Require_Known (Syn.Repeated_Element (Of_Tree, Given));
                  end if;

               when Syn.Mixed_Array_Repetition =>
                  Check_Mixed_Array_Repetition
                    (Of_Tree, Label, Given, Shape.Length, Shape.Element,
                     Static_Image => Static_Image);
                  if Static_Image then
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Given)
                     loop
                        Require_Known
                          (Syn.Nth_Element (Of_Tree, Given, Position));
                     end loop;
                     Require_Known (Syn.Repeated_Element (Of_Tree, Given));
                  end if;

               when Syn.Zeroed_Literal =>
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Given, Ty.Fixed_Array);
                  Landin.Checking.Note_Array
                    (Types.all, Of_Tree, Given,
                     Shape.Length, Shape.Element);

               when Syn.Name_Reference =>
                  declare
                     Is_Storage : constant Boolean :=
                       (if Static_Image
                        then Res.Verdict_Of
                               (Meanings.all, Of_Tree, Given) = Res.Bound
                          and then Res.Sort_Of
                            (Meanings.all,
                             Res.Bound_To
                               (Meanings.all, Of_Tree, Given))
                              = Res.Module_Binding
                        else Is_Direct_Binding_Name (Of_Tree, Given));
                     Got : constant Ty.Type_Kind :=
                       (if Is_Storage
                        then Selected_From (Of_Tree, Given)
                        else Synthesise (Of_Tree, Given));
                  begin
                     if Got = Ty.Ill_Typed then
                        null;
                     elsif Is_Storage
                       and then
                         (Got /= Ty.Fixed_Array
                          or else Landin.Checking.Array_Length
                            (Types.all, Of_Tree, Given) /= Shape.Length
                          or else Landin.Checking.Array_Element
                            (Types.all, Of_Tree, Given) /= Shape.Element)
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Given),
                           Message => "this is not an array of the"
                                      & " variant payload's type",
                           Note    => "D17: an array's length and element"
                                      & " type are its identity",
                           Related => Syn.Origin (Of_Tree, Label),
                           Because => "the payload field named here",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Given);
                     end if;
                  end;

               when Syn.Member_Selection =>
                  declare
                     Is_Storage : constant Boolean :=
                       (if Static_Image
                        then Is_Direct_Module_Field (Of_Tree, Given)
                        else Syn.Kind
                          (Of_Tree, Syn.Target_Of (Of_Tree, Given))
                            = Syn.Name_Reference);
                     Admitted : constant Boolean :=
                       Is_Storage
                       and then Admit_Array_Field (Of_Tree, Given);
                     Got : constant Ty.Type_Kind :=
                       (if Admitted
                        then Selected_From (Of_Tree, Given)
                        else Synthesise (Of_Tree, Given));
                  begin
                     if Got = Ty.Ill_Typed then
                        null;
                     elsif Is_Storage
                       and then
                         (not Admitted
                          or else Landin.Checking.Array_Length
                            (Types.all, Of_Tree, Given) /= Shape.Length
                          or else Landin.Checking.Array_Element
                            (Types.all, Of_Tree, Given) /= Shape.Element)
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Given),
                           Message => "this is not an array field of the"
                                      & " variant payload's type",
                           Note    => "D17: an array's length and element"
                                      & " type are its identity",
                           Related => Syn.Origin (Of_Tree, Label),
                           Because => "the payload field named here",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Given);
                     end if;
                  end;

               when others =>
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Given),
                     Message =>
                       (if Static_Image
                        then "a module fixed-array case payload takes a"
                          & " literal, repetition, `zeroed` or a module"
                          & " array or array-field name"
                        else "a fixed-array case payload takes a literal,"
                          & " repetition, `zeroed` or an array or"
                          & " array-field name"),
                     Refused => Bad.Array_Value,
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Given);
            end case;

            if Subtree_Was_Refused (Given) then
               Landin.Checking.Refuse (Types.all, Of_Tree, Given);
            end if;
         end Check_Fixed_Array_Payload;
      begin
         pragma Assert (Syn.Kind (Body_Tree.all, Part) = Syn.Variant_Part);

         if Syn.Kind (Of_Tree, Value) = Syn.Name_Reference then
            Nominal := Value;
         elsif Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
           and then Syn.Constructed_Type (Of_Tree, Value) /= Syn.No_Node
         then
            Nominal := Syn.Constructed_Type (Of_Tree, Value);
         else
            Bad.Report
              (Item    => Bad.Unsupported_Use,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Value),
               Message => "a variant part takes a bare case name or a"
                          & " labelled case construction",
               Refused => Bad.Variant_Value,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
            return;
         end if;

         if Res.Verdict_Of (Meanings.all, Of_Tree, Nominal) = Res.Bound then
            Means := Res.Bound_To (Meanings.all, Of_Tree, Nominal);
         end if;

         if Means /= Res.No_Declaration
           and then Res.Sort_Of (Meanings.all, Means) = Res.Case_Name
         then
            for Candidate in 1 .. Syn.Case_Count (Body_Tree.all, Part) loop
               if Res.Source_Of (Meanings.all, Means)
                    = Syn.Source_Of (Body_Tree.all)
                 and then Res.Node_Of (Meanings.all, Means)
                    = Syn.Nth_Case (Body_Tree.all, Part, Candidate)
               then
                  Which := Candidate;
                  exit;
               end if;
            end loop;
         end if;

         if Which = 0 then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Nominal),
               Message => "this case does not belong to the variant part"
                          & " selected here",
               Note    => "D76: a case is identified by the variant part"
                          & " that declared it",
               Related => Syn.Origin (Of_Tree, Site),
               Because => "the variant part selected here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
            return;
         end if;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Value)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Value, Ty.Not_Typed);
            Landin.Checking.Note_Field
              (Types.all, Of_Tree, Value, Which);
         end if;

         declare
            Case_Node : constant Syn.Node_Id :=
              Syn.Nth_Case (Body_Tree.all, Part, Which);
            Count : constant Natural :=
              Syn.Payload_Field_Count (Body_Tree.all, Case_Node);
         begin
            if Syn.Kind (Of_Tree, Value) = Syn.Name_Reference then
               if Count > 0 then
                  Bad.Report
                    (Item    => Bad.Type_Mismatch,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Value),
                     Message => "this case has a payload, so its fields"
                                & " must be constructed",
                     Note    => "D76: only a payload-free case is a bare"
                                & " case value",
                     Related => Syn.Origin (Body_Tree.all, Case_Node),
                     Because => "declared with a payload here",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Value);
               end if;
               return;
            end if;

            declare
               type Node_List is array (Natural range <>) of Syn.Node_Id;
               First : Node_List (1 .. Count) := [others => Syn.No_Node];
            begin
               for Position in
                 1 .. Syn.Field_Value_Count (Of_Tree, Value)
               loop
                  declare
                     Label : constant Syn.Node_Id :=
                       Syn.Nth_Field_Value (Of_Tree, Value, Position);
                     Given : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree, Label);
                     Payload_Field : Natural := 0;
                  begin
                     for Candidate in 1 .. Count loop
                        if Syn.Name (Of_Tree, Label)
                          = Syn.Name
                              (Body_Tree.all,
                               Syn.Nth_Payload_Field
                                 (Body_Tree.all, Case_Node, Candidate))
                        then
                           Payload_Field := Candidate;
                           exit;
                        end if;
                     end loop;

                     if Payload_Field = 0 then
                        Bad.Report
                          (Item    => Bad.Unresolved_Field,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Anchor (Of_Tree, Label),
                           Message => "this variant case has no payload"
                                      & " field called `"
                                      & Spelled (Syn.Name (Of_Tree, Label))
                                      & "`",
                           Note    => "D76: a case construction has exactly"
                                      & " its declared payload fields",
                           Into    => Found);
                        Failed := True;
                     elsif First (Payload_Field) /= Syn.No_Node then
                        Bad.Report
                          (Item    => Bad.Field_Named_Twice,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Anchor (Of_Tree, Label),
                           Message => "this payload field is named twice",
                           Note    => "D76: each case payload field is"
                                      & " written once",
                           Related => Syn.Origin
                             (Of_Tree, First (Payload_Field)),
                           Because => "first named here",
                           Into    => Found);
                        Failed := True;
                     else
                        First (Payload_Field) := Label;
                        Landin.Checking.Note_Field
                          (Types.all, Of_Tree, Label, Payload_Field);

                        declare
                           Shape : constant Landin.Checking.Field_Shape :=
                             Landin.Checking.Nth_Variant_Case_Field
                               (Types.all, Wrote, Field, Which,
                                Payload_Field);
                        begin
                           case Shape.Kind is
                              when Landin.Checking.Scalar_Field =>
                                 if Syn.Kind (Of_Tree, Given)
                                      = Syn.Zeroed_Literal
                                 then
                                    Landin.Checking.Note
                                      (Types.all, Of_Tree, Given,
                                       Shape.Element);
                                 else
                                    Require
                                      (Of_Tree, Given, Shape.Element,
                                       Syn.Origin (Of_Tree, Label),
                                       "the variant payload field named"
                                       & " here");
                                 end if;

                                 if Static_Image
                                   and then Landin.Checking.Type_Of
                                     (Types.all, Of_Tree, Given)
                                       /= Ty.Ill_Typed
                                 then
                                    Refuse_Static_Image_Subtree
                                      (Of_Tree, Given,
                                       "a module variant payload field");

                                    if Subtree_Was_Refused (Given) then
                                       Landin.Checking.Refuse
                                         (Types.all, Of_Tree, Given);
                                    elsif not Is_Known (Of_Tree, Given) then
                                       Bad.Report
                                         (Item    =>
                                            Bad.Not_Known_At_Compile_Time,
                                          Source  => Syn.Source_Of (Of_Tree),
                                          Where   => Syn.Where
                                            (Of_Tree, Given),
                                          Message => "this variant payload"
                                            & " value has to be known when"
                                            & " the module image is formed",
                                          Note    => "[1940]: nothing runs"
                                            & " before the entry point"
                                            & " [1460]",
                                          Into    => Found);
                                       Landin.Checking.Refuse
                                         (Types.all, Of_Tree, Given);
                                    end if;
                                 end if;

                              when Landin.Checking.Fixed_Array_Field =>
                                 Check_Fixed_Array_Payload
                                   (Label, Given, Shape);

                              when Landin.Checking.Aggregate_Field =>
                                 raise Landin.Compiler_Defect with
                                   "a nested aggregate payload reached D76";

                              when Landin.Checking.Variant_Field =>
                                 raise Landin.Compiler_Defect with
                                   "a nested variant payload reached D76";
                           end case;
                        end;

                        Failed := Failed
                          or else Landin.Checking.Type_Of
                            (Types.all, Of_Tree, Given) = Ty.Ill_Typed;
                     end if;
                  end;
               end loop;

               declare
                  Fill : constant Syn.Node_Id :=
                    Syn.Struct_Fill (Of_Tree, Value);
                  Missing : Ada.Strings.Unbounded.Unbounded_String;
                  Missing_Count : Natural := 0;
               begin
                  if Fill /= Syn.No_Node
                    and then Syn.Kind (Of_Tree, Fill)
                               /= Syn.Zeroed_Literal
                  then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Fill),
                        Message => "a case construction's trailing `of`"
                                   & " accepts only `zeroed`",
                        Refused => Bad.Variant_Value,
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree, Fill);
                     Failed := True;
                  end if;

                  if Fill = Syn.No_Node then
                     for Candidate in First'Range loop
                        if First (Candidate) = Syn.No_Node then
                           Missing_Count := Missing_Count + 1;
                           if Missing_Count > 1 then
                              Ada.Strings.Unbounded.Append (Missing, ", ");
                           end if;
                           Ada.Strings.Unbounded.Append
                             (Missing, "`"
                              & Spelled
                                  (Syn.Name
                                     (Body_Tree.all,
                                      Syn.Nth_Payload_Field
                                        (Body_Tree.all, Case_Node,
                                         Candidate)))
                              & "`");
                        end if;
                     end loop;

                     if Missing_Count > 0 then
                        Bad.Report
                          (Item    => Bad.Field_Not_Given,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Value),
                           Message => "this case construction gives no"
                                      & " value for "
                                      & Ada.Strings.Unbounded.To_String
                                          (Missing),
                           Note    => "D76: every payload field is labelled"
                                      & " or covered by trailing `of"
                                      & " zeroed`",
                           Into    => Found);
                        Failed := True;
                     end if;
                  end if;
               end;
            end;
         end;

         if Failed then
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
         end if;
      end Check_Variant_Value;

      --  D64: a labelled struct literal is contextual.  The destination
      --  supplies [0710]'s nominal body; labels may be written in any order,
      --  but each names one scalar field at most once.  A trailing
      --  `of zeroed` covers every field not named explicitly, including an
      --  array field through D49's whole-field zero image.
      procedure Check_Struct_Literal
        (Of_Tree      : Syn.Tree;
         Literal      : Syn.Node_Id;
         Wrote        : Res.Declaration_Id;
         Static_Image : Boolean)
      is
         Count : constant Natural :=
           (if Landin.Checking.Has_Layout (Types.all, Wrote)
            then Landin.Checking.Layout_Field_Count (Types.all, Wrote)
            else 0);
         type Node_List is array (Natural range <>) of Syn.Node_Id;
         First : Node_List (1 .. Count) := [others => Syn.No_Node];
         Failed : Boolean := False;

         function Subtree_Was_Refused (Node : Syn.Node_Id) return Boolean;

         function Subtree_Was_Refused (Node : Syn.Node_Id) return Boolean is
         begin
            if Node = Syn.No_Node then
               return False;
            end if;

            if Landin.Checking.Type_Of (Types.all, Of_Tree, Node)
                 = Ty.Ill_Typed
            then
               return True;
            end if;

            for Slot in 1 .. Syn.Slot_Count (Of_Tree, Node) loop
               if Subtree_Was_Refused (Syn.Slot (Of_Tree, Node, Slot)) then
                  return True;
               end if;
            end loop;
            return False;
         end Subtree_Was_Refused;

         procedure Check_Aggregate_Field
           (Field : Syn.Node_Id; Value : Syn.Node_Id; Which : Positive);

         procedure Check_Aggregate_Field
           (Field : Syn.Node_Id; Value : Syn.Node_Id; Which : Positive)
         is
            Expected : constant Res.Declaration_Id :=
              Landin.Checking.Field_Shape_Of
                (Types.all, Wrote, Which).Aggregate_Body;
            Got : Ty.Type_Kind;
         begin
            if Static_Image then
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Value),
                  Message => "a module struct image cannot yet contain an"
                             & " ordinary-child field value",
                  Refused => Bad.Struct_Value,
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Value);
               return;
            end if;

            if Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal then
               Landin.Checking.Note
                 (Types.all, Of_Tree, Value, Ty.Aggregate);
               Landin.Checking.Note_Body
                 (Types.all, Of_Tree, Value, Expected);
               return;
            elsif Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal then
               if Construction_Agrees
                    (Of_Tree, Value, Expected,
                     Syn.Origin (Of_Tree, Field),
                     "this ordinary-child field")
               then
                  Check_Struct_Literal
                    (Of_Tree, Value, Expected, Static_Image => False);
               end if;
               return;
            elsif Is_Direct_Binding_Name (Of_Tree, Value)
              or else Syn.Kind (Of_Tree, Value) = Syn.Member_Selection
            then
               Got := Selected_From (Of_Tree, Value);
            else
               Got := Synthesise (Of_Tree, Value);
            end if;

            if Got = Ty.Aggregate
              and then Landin.Checking.Body_Of
                (Types.all, Of_Tree, Value) = Expected
            then
               if Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal then
                  Check_Struct_Literal
                    (Of_Tree, Value, Expected, Static_Image => False);
               end if;
            elsif Got /= Ty.Ill_Typed then
               Bad.Report
                 (Item    => Bad.Type_Mismatch,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Value),
                  Message => "this is not the nominal struct type named by"
                             & " the ordinary-child field",
                  Note    => "[0710]: ordinary struct identity is nominal",
                  Related => Syn.Origin (Of_Tree, Field),
                  Because => "the child field named here",
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Value);
            end if;
         end Check_Aggregate_Field;

         procedure Check_Array_Field
           (Field : Syn.Node_Id; Value : Syn.Node_Id; Which : Positive);

         procedure Check_Array_Field
           (Field : Syn.Node_Id; Value : Syn.Node_Id; Which : Positive)
         is
            Expected : constant Landin.Checking.Element_Count :=
              Landin.Checking.Field_Array_Length
                (Types.all, Wrote, Which);
            Element : constant Ty.Scalar_Name :=
              Landin.Checking.Field_Array_Element
                (Types.all, Wrote, Which);

            procedure Require_Known (Each : Syn.Node_Id);

            procedure Require_Known (Each : Syn.Node_Id) is
            begin
               if not Subtree_Was_Refused (Each)
                 and then not Is_Known (Of_Tree, Each)
               then
                  Bad.Report
                    (Item    => Bad.Not_Known_At_Compile_Time,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Each),
                     Message => "this array-field image value has to be"
                                & " known when the module image is formed",
                     Note    => "[1940]: nothing runs before the entry"
                                & " point [1460]",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Each);
               end if;
            end Require_Known;
         begin
            --  D65 makes the label the same contextual destination as the
            --  selected field in D49--D53.  Each established array spelling
            --  keeps its own shape check and diagnostic owner.  D67 admits
            --  the finite and zero static forms; D68 adds D34/D38's compact
            --  repetitions, D69 follows one direct module-array image name,
            --  and D71 follows one directly selected module struct field
            --  without making either source a general value.
            if Static_Image then
               case Syn.Kind (Of_Tree, Value) is
                  when Syn.Array_Literal =>
                     Check_Array_Literal
                       (Of_Tree, Field, Value, Expected, Element,
                        Static_Image => True);

                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        Require_Known
                          (Syn.Nth_Element (Of_Tree, Value, Position));
                     end loop;

                     if Subtree_Was_Refused (Value) then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     end if;

                  when Syn.Array_Repetition =>
                     Check_Array_Repetition
                       (Of_Tree, Field, Value, Expected, Element,
                        Static_Image => True);
                     Require_Known
                       (Syn.Repeated_Element (Of_Tree, Value));

                     if Subtree_Was_Refused (Value) then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     end if;

                  when Syn.Mixed_Array_Repetition =>
                     Check_Mixed_Array_Repetition
                       (Of_Tree, Field, Value, Expected, Element,
                        Static_Image => True);
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        Require_Known
                          (Syn.Nth_Element (Of_Tree, Value, Position));
                     end loop;
                     Require_Known
                       (Syn.Repeated_Element (Of_Tree, Value));

                     if Subtree_Was_Refused (Value) then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     end if;

                  when Syn.Zeroed_Literal =>
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Value, Ty.Fixed_Array);
                     Landin.Checking.Note_Array
                       (Types.all, Of_Tree, Value, Expected, Element);

                  when Syn.Name_Reference =>
                     declare
                        Is_Module_Storage : constant Boolean :=
                          Res.Verdict_Of (Meanings.all, Of_Tree, Value)
                            = Res.Bound
                          and then Res.Sort_Of
                            (Meanings.all,
                             Res.Bound_To
                               (Meanings.all, Of_Tree, Value))
                              = Res.Module_Binding;
                        Got : constant Ty.Type_Kind :=
                          (if Is_Module_Storage
                           then Selected_From (Of_Tree, Value)
                           else Synthesise (Of_Tree, Value));
                     begin
                        if Got = Ty.Ill_Typed then
                           --  Resolution or the source declaration already
                           --  owns the report.  The contextual label adds no
                           --  second refusal.
                           null;
                        elsif Is_Module_Storage
                          and then
                            (Got /= Ty.Fixed_Array
                             or else Landin.Checking.Array_Length
                               (Types.all, Of_Tree, Value) /= Expected
                             or else Landin.Checking.Array_Element
                               (Types.all, Of_Tree, Value) /= Element)
                        then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Value),
                              Message => "this is not a module array of the"
                                         & " type named by the struct field",
                              Note    => "D17: an array's length and element"
                                         & " type are its identity",
                              Related => Syn.Origin (Of_Tree, Field),
                              Because => "the field named here",
                              Into    => Found);
                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Value);
                        end if;
                     end;

                  when Syn.Member_Selection =>
                     declare
                        Is_Module_Storage : constant Boolean :=
                          Is_Direct_Module_Field (Of_Tree, Value);
                        Admitted : constant Boolean :=
                          Is_Module_Storage
                          and then Admit_Array_Field (Of_Tree, Value);
                        Got : constant Ty.Type_Kind :=
                          (if Admitted
                           then Selected_From (Of_Tree, Value)
                           else Synthesise (Of_Tree, Value));
                     begin
                        if Got = Ty.Ill_Typed then
                           --  The root declaration, its layout or the field
                           --  lookup already owns the report.
                           null;
                        elsif Is_Module_Storage
                          and then not Is_Module_Array_Field
                            (Of_Tree, Value, Expected, Element)
                        then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Value),
                              Message => "this is not an array field of the"
                                         & " type named by this label",
                              Note    => "D17: an array's length and element"
                                         & " type are its identity",
                              Related => Syn.Origin (Of_Tree, Field),
                              Because => "the field named here",
                              Into    => Found);
                           Landin.Checking.Refuse
                             (Types.all, Of_Tree, Value);
                        end if;
                     end;

                  when others =>
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Value),
                        Message => "a module struct array field takes a"
                                   & " finite literal, repetition, `zeroed`"
                                   & " or a module array or array-field name"
                                   & " in this slice",
                        Refused => Bad.Array_Value,
                        Into    => Found);
                     Landin.Checking.Refuse
                       (Types.all, Of_Tree, Value);
               end case;
               return;
            end if;

            case Syn.Kind (Of_Tree, Value) is
               when Syn.Array_Literal =>
                  Check_Array_Literal
                    (Of_Tree, Field, Value, Expected, Element,
                     Static_Image => False);

               when Syn.Array_Repetition =>
                  Check_Array_Repetition
                    (Of_Tree, Field, Value, Expected, Element,
                     Static_Image => False);

               when Syn.Mixed_Array_Repetition =>
                  Check_Mixed_Array_Repetition
                    (Of_Tree, Field, Value, Expected, Element,
                     Static_Image => False);

               when Syn.Zeroed_Literal =>
                  Landin.Checking.Note
                    (Types.all, Of_Tree, Value, Ty.Fixed_Array);
                  Landin.Checking.Note_Array
                    (Types.all, Of_Tree, Value, Expected, Element);

               when others =>
                  declare
                     Admitted : constant Boolean :=
                       Syn.Kind (Of_Tree, Value) = Syn.Member_Selection
                       and then Admit_Array_Field (Of_Tree, Value);
                     Got : constant Ty.Type_Kind :=
                       (if Admitted
                            or else Is_Direct_Binding_Name (Of_Tree, Value)
                        then Selected_From (Of_Tree, Value)
                        else Synthesise (Of_Tree, Value));
                  begin
                     if Got = Ty.Ill_Typed then
                        null;
                     elsif Got /= Ty.Fixed_Array
                       or else Landin.Checking.Array_Length
                         (Types.all, Of_Tree, Value) /= Expected
                       or else Landin.Checking.Array_Element
                         (Types.all, Of_Tree, Value) /= Element
                     then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree),
                           Where   => Syn.Where (Of_Tree, Value),
                           Message => "this is not an array of the type"
                                      & " named by the struct field",
                           Note    => "D17: an array's length and element"
                                      & " type are its identity",
                           Related => Syn.Origin (Of_Tree, Field),
                           Because => "the field named here",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     end if;
                  end;
            end case;
         end Check_Array_Field;
      begin
         --  A refused field or a target extent overflow leaves the body
         --  identified but deliberately without a layout.  That refusal
         --  owns the diagnostic; the contextual literal must neither ask
         --  the absent layout for field shapes nor add a cascade.
         if not Landin.Checking.Has_Layout (Types.all, Wrote) then
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
            return;
         end if;

         if Landin.Checking.Type_Of (Types.all, Of_Tree, Literal)
              = Ty.Ill_Typed
         then
            return;
         elsif Landin.Checking.Type_Of (Types.all, Of_Tree, Literal)
                 = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Literal, Ty.Aggregate);
            Landin.Checking.Note_Body (Types.all, Of_Tree, Literal, Wrote);
         end if;

         for Position in 1 .. Syn.Field_Value_Count (Of_Tree, Literal) loop
            declare
               Field : constant Syn.Node_Id :=
                 Syn.Nth_Field_Value (Of_Tree, Literal, Position);
               Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Field);
               Which : constant Natural :=
                 Field_At (Wrote, Syn.Name (Of_Tree, Field));
            begin
               if Which = 0 then
                  Bad.Report
                    (Item    => Bad.Unresolved_Field,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Anchor (Of_Tree, Field),
                     Message => "this struct has no field called `"
                                & Spelled (Syn.Name (Of_Tree, Field)) & "`",
                     Note    => "[0750]: a struct has the fields it was"
                                & " declared with, and no others",
                     Into    => Found);
                  Failed := True;
               elsif First (Which) /= Syn.No_Node then
                  Bad.Report
                    (Item    => Bad.Field_Named_Twice,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Anchor (Of_Tree, Field),
                     Message => "the field `" & Field_Named (Wrote, Which)
                                & "` is named twice in this struct literal",
                     Note    => "D64: each labelled field is written once",
                     Related => Syn.Origin (Of_Tree, First (Which)),
                     Because => "first named here",
                     Into    => Found);
                  Failed := True;
               else
                  First (Which) := Field;
                  Landin.Checking.Note_Field
                    (Types.all, Of_Tree, Field, Which);

                  case Landin.Checking.Field_Kind_Of
                    (Types.all, Wrote, Which)
                  is
                     when Landin.Checking.Scalar_Field =>
                        declare
                           Held : constant Ty.Scalar_Name :=
                             Landin.Checking.Field_Type
                               (Types.all, Wrote, Which);
                        begin
                           if Syn.Kind (Of_Tree, Value)
                                = Syn.Zeroed_Literal
                           then
                              --  D65 extends D42's contextual zero image to
                              --  the scalar field named by this label.
                              Landin.Checking.Note
                                (Types.all, Of_Tree, Value, Held);
                           else
                              Require
                                (Of_Tree, Value, Held,
                                 Syn.Origin (Of_Tree, Field),
                                 "the struct field named here");
                           end if;

                           if Static_Image
                             and then Landin.Checking.Type_Of
                               (Types.all, Of_Tree, Value) /= Ty.Ill_Typed
                           then
                              Refuse_Static_Image_Subtree
                                (Of_Tree, Value,
                                 "a module struct literal field");

                              if Subtree_Was_Refused (Value) then
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              elsif not Is_Known (Of_Tree, Value) then
                                 Bad.Report
                                   (Item    =>
                                      Bad.Not_Known_At_Compile_Time,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Value),
                                    Message => "this struct field value has"
                                               & " to be known when the"
                                               & " module image is formed",
                                    Note    => "[1940]: nothing runs before"
                                               & " the entry point [1460]",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              end if;
                           end if;
                        end;

                     when Landin.Checking.Fixed_Array_Field =>
                        Check_Array_Field (Field, Value, Which);

                     when Landin.Checking.Aggregate_Field =>
                        Check_Aggregate_Field (Field, Value, Which);

                     when Landin.Checking.Variant_Field =>
                        Check_Variant_Value
                          (Of_Tree, Field, Value, Wrote, Which,
                           Static_Image);
                  end case;

                  Failed := Failed
                    or else Landin.Checking.Type_Of
                      (Types.all, Of_Tree, Value) = Ty.Ill_Typed;
               end if;
            end;
         end loop;

         declare
            Fill : constant Syn.Node_Id :=
              Syn.Struct_Fill (Of_Tree, Literal);
            Missing : Ada.Strings.Unbounded.Unbounded_String;
            Missing_Count : Natural := 0;
         begin
            if Fill /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Fill) /= Syn.Zeroed_Literal
            then
               Bad.Report
                 (Item    => Bad.Unsupported_Use,
                  Source  => Syn.Source_Of (Of_Tree),
                  Where   => Syn.Where (Of_Tree, Fill),
                  Message => "a struct literal's trailing `of` accepts only"
                             & " `zeroed` in this slice",
                  Refused => Bad.Struct_Value,
                  Into    => Found);
               Landin.Checking.Refuse (Types.all, Of_Tree, Fill);
               Failed := True;
            end if;

            if Fill = Syn.No_Node then
               for Which in First'Range loop
                  if First (Which) = Syn.No_Node then
                     Missing_Count := Missing_Count + 1;
                     if Missing_Count > 1 then
                        Ada.Strings.Unbounded.Append (Missing, ", ");
                     end if;
                     Ada.Strings.Unbounded.Append
                       (Missing, "`" & Field_Named (Wrote, Which) & "`");
                  end if;
               end loop;

               if Missing_Count > 0 then
                  Bad.Report
                    (Item    => Bad.Field_Not_Given,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Literal),
                     Message => "this struct literal gives no value for "
                                & Ada.Strings.Unbounded.To_String (Missing),
                     Note    => "D64: every field is labelled or covered by"
                                & " a trailing `of zeroed`",
                     Into    => Found);
                  Failed := True;
               end if;
            end if;
         end;

         if Failed then
            Landin.Checking.Refuse (Types.all, Of_Tree, Literal);
         end if;
      end Check_Struct_Literal;

      procedure Check_Mixed_Array_Repetition
        (Of_Tree      : Syn.Tree;
         Site_Node    : Syn.Node_Id;
         Repetition   : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean)
      is
         Prefix : constant Natural := Syn.Element_Count (Of_Tree, Repetition);
      begin
         --  Check_Module_Value may already have refused a non-static subtree
         --  and marked the complete hybrid ill typed before this contextual
         --  shape walk.  Do not note the same node a second time.
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Repetition)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Repetition, Ty.Fixed_Array);
            Landin.Checking.Note_Array
              (Types.all, Of_Tree, Repetition, Expected, Element);
         end if;

         --  The parser makes the prefix nonempty.  D36/D37 also require at
         --  least one destination position to remain for the repeated suffix.
         if Landin.Checking.Element_Count (Prefix) >= Expected then
            Bad.Report
              (Item    => Bad.Type_Mismatch,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Repetition),
               Message => "this mixed repetition leaves no array suffix to"
                          & " fill",
               Note    => "D36/D37: a prefix requires 1 <= k < N",
               Related => Syn.Origin (Of_Tree, Site_Node),
               Because => "the array context here",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Repetition);
         end if;

         for Position in 1 .. Prefix loop
            Require
              (Of_Tree, Syn.Nth_Element (Of_Tree, Repetition, Position),
               Element, Syn.Origin (Of_Tree, Site_Node),
               "the array element type");
         end loop;

         Require
           (Of_Tree, Syn.Repeated_Element (Of_Tree, Repetition), Element,
            Syn.Origin (Of_Tree, Site_Node), "the array element type");

         if Static_Image then
            declare
               procedure Refuse_Excluded_Subtree (Where : Syn.Node_Id);

               procedure Refuse_Excluded_Subtree (Where : Syn.Node_Id) is
                  What : constant String :=
                    (case Syn.Kind (Of_Tree, Where) is
                        when Syn.Member_Selection => "a field selection",
                        when Syn.Element_Index    => "an array index",
                        when Syn.Array_Literal    => "a nested array literal",
                        when others               => "");
               begin
                  if What /= "" then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Where),
                        Message => What & " is not enabled as a module"
                                   & " mixed array repetition element",
                        Refused => Bad.Array_Value,
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree, Where);
                     return;
                  end if;

                  for Slot in 1 .. Syn.Slot_Count (Of_Tree, Where) loop
                     Refuse_Excluded_Subtree
                       (Syn.Slot (Of_Tree, Where, Slot));
                  end loop;
               end Refuse_Excluded_Subtree;
            begin
               for Position in 1 .. Prefix loop
                  Refuse_Excluded_Subtree
                    (Syn.Nth_Element (Of_Tree, Repetition, Position));
               end loop;
               Refuse_Excluded_Subtree
                 (Syn.Repeated_Element (Of_Tree, Repetition));
            end;
         end if;
      end Check_Mixed_Array_Repetition;

      procedure Check_Array_Repetition
        (Of_Tree      : Syn.Tree;
         Site_Node    : Syn.Node_Id;
         Repetition   : Syn.Node_Id;
         Expected     : Landin.Checking.Element_Count;
         Element      : Ty.Scalar_Name;
         Static_Image : Boolean)
      is
         Count : constant Syn.Node_Id :=
           Syn.Repetition_Count (Of_Tree, Repetition);
      begin
         --  D32's repetition is contextual like `zeroed`: the destination
         --  supplies the complete array shape, while one scalar expression
         --  supplies the value stored into every element.
         if Landin.Checking.Type_Of (Types.all, Of_Tree, Repetition)
              = Ty.Undecided
         then
            Landin.Checking.Note
              (Types.all, Of_Tree, Repetition, Ty.Fixed_Array);
            Landin.Checking.Note_Array
              (Types.all, Of_Tree, Repetition, Expected, Element);
         end if;

         --  D34 deliberately does not decide whether [0580]'s zero-length
         --  fixed-array type is legal source.  Repetition needs at least one
         --  destination position, so a zero contextual extent is refused at
         --  this construct rather than admitted as a zero-length array value.
         if Expected = 0 then
            Bad.Report
              (Item    => Bad.Unsupported_Use,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Repetition),
               Message => "array repetition needs a nonzero contextual length",
               Refused => Bad.Array_Value,
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Repetition);
         end if;

         if Count /= Syn.No_Node then
            declare
               Snap : constant Landin.Source.Snapshot :=
                 Source (Context, Syn.Source_Of (Of_Tree));
               Text : constant String :=
                 Landin.Source.Slice
                   (Snap, Syn.Digit_Span (Of_Tree, Count));
               Value      : Ty.Magnitude;
               Overflowed : Boolean;
            begin
               Ty.Evaluate
                 (Text, Syn.Base (Of_Tree, Count), Value, Overflowed);

               if Overflowed
                 or else Value /= Ty.Magnitude (Expected)
               then
                  Bad.Report
                    (Item    => Bad.Type_Mismatch,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Count),
                     Message => "this repetition count does not match the"
                                & " array context",
                     Note    => "D32: a written repetition count is exactly"
                                & " the destination array's length",
                     Related => Syn.Origin (Of_Tree, Site_Node),
                     Because => "the array context here",
                     Into    => Found);
                  Landin.Checking.Refuse
                    (Types.all, Of_Tree, Repetition);
               end if;
            end;
         end if;

         Require
           (Of_Tree, Syn.Repeated_Element (Of_Tree, Repetition), Element,
            Syn.Origin (Of_Tree, Site_Node), "the array element type");

         if Static_Image then
            declare
               procedure Refuse_Excluded_Subtree (Where : Syn.Node_Id);

               procedure Refuse_Excluded_Subtree (Where : Syn.Node_Id) is
                  What : constant String :=
                    (case Syn.Kind (Of_Tree, Where) is
                        when Syn.Member_Selection => "a field selection",
                        when Syn.Element_Index    => "an array index",
                        when Syn.Array_Literal    => "a nested array literal",
                        when others               => "");
               begin
                  if What /= "" then
                     Bad.Report
                       (Item    => Bad.Unsupported_Use,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Where),
                        Message => What & " is not enabled as a module"
                                   & " array repetition element",
                        Refused => Bad.Array_Value,
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree, Where);
                     return;
                  end if;

                  for Slot in 1 .. Syn.Slot_Count (Of_Tree, Where) loop
                     Refuse_Excluded_Subtree
                       (Syn.Slot (Of_Tree, Where, Slot));
                  end loop;
               end Refuse_Excluded_Subtree;
            begin
               Refuse_Excluded_Subtree
                 (Syn.Repeated_Element (Of_Tree, Repetition));
            end;
         end if;
      end Check_Array_Repetition;

      --  D77: matching is contextual to one directly selected variant
      --  part.  Case identity comes from resolution, while declaration
      --  order supplies the tag number shared with D76 and lowering.
      procedure Check_Match
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind)
      is
         Subject : constant Syn.Node_Id := Syn.Match_Subject (Of_Tree, Node);

         function Binding_Id (Binding : Syn.Node_Id)
           return Res.Declaration_Id;

         procedure Refuse_Bindings (Arm : Syn.Node_Id);

         function Binding_Id (Binding : Syn.Node_Id)
           return Res.Declaration_Id
         is
         begin
            for Id in Res.Declaration_Id'(1)
                      .. Res.Declaration_Id
                           (Res.Declaration_Count (Meanings.all))
            loop
               if Res.Source_Of (Meanings.all, Id) = Syn.Source_Of (Of_Tree)
                 and then Res.Node_Of (Meanings.all, Id) = Binding
               then
                  return Id;
               end if;
            end loop;
            raise Landin.Compiler_Defect with
              "a match binding the resolver never recorded";
         end Binding_Id;

         procedure Refuse_Bindings (Arm : Syn.Node_Id) is
         begin
            for Position in 1 .. Syn.Match_Binding_Count (Of_Tree, Arm)
            loop
               declare
                  Binding : constant Syn.Node_Id :=
                    Syn.Nth_Match_Binding (Of_Tree, Arm, Position);
                  Id : constant Res.Declaration_Id := Binding_Id (Binding);
               begin
                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Binding);
               end;
            end loop;
         end Refuse_Bindings;
      begin
         if not Admit_Variant_Field (Of_Tree, Subject) then
            declare
               Got : constant Ty.Type_Kind := Synthesise (Of_Tree, Subject);
            begin
               if Got /= Ty.Ill_Typed then
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Subject),
                     Message => "a match subject must directly select a"
                                & " variant part",
                     Refused => Bad.Variant_Value,
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Subject);
               end if;
            end;
            return;
         end if;

         declare
            From : constant Syn.Node_Id :=
              Syn.Target_Of (Of_Tree, Subject);
            Wrote : constant Res.Declaration_Id :=
              Landin.Checking.Body_Of (Types.all, Of_Tree, From);
            Field : constant Positive := Positive
              (Landin.Checking.Field_Index (Types.all, Of_Tree, Subject));
            Body_Tree : constant not null access constant Syn.Tree :=
              Tree_For (Res.Source_Of (Meanings.all, Wrote));
            Body_Node : constant Syn.Node_Id :=
              Syn.Declared_Type
                (Body_Tree.all, Res.Node_Of (Meanings.all, Wrote));
            Part : constant Syn.Node_Id :=
              Syn.Nth_Field (Body_Tree.all, Body_Node, Field);
            Count : constant Positive := Syn.Case_Count
              (Body_Tree.all, Part);
            type Node_List is array (Positive range <>) of Syn.Node_Id;
            First : Node_List (1 .. Count) := [others => Syn.No_Node];
         begin
            for Position in 1 .. Syn.Match_Arm_Count (Of_Tree, Node) loop
               declare
                  Arm : constant Syn.Node_Id :=
                    Syn.Nth_Match_Arm (Of_Tree, Node, Position);
                  Pattern : constant Syn.Node_Id :=
                    Syn.Match_Pattern (Of_Tree, Arm);
                  Means : Res.Declaration_Id := Res.No_Declaration;
                  Which : Natural := 0;
               begin
                  if Res.Verdict_Of (Meanings.all, Of_Tree, Pattern)
                       = Res.Bound
                  then
                     Means := Res.Bound_To (Meanings.all, Of_Tree, Pattern);
                  end if;

                  if Means /= Res.No_Declaration
                    and then Res.Sort_Of (Meanings.all, Means) = Res.Case_Name
                  then
                     for Candidate in 1 .. Count loop
                        if Res.Source_Of (Meanings.all, Means)
                             = Syn.Source_Of (Body_Tree.all)
                          and then Res.Node_Of (Meanings.all, Means)
                             = Syn.Nth_Case
                                 (Body_Tree.all, Part, Candidate)
                        then
                           Which := Candidate;
                           exit;
                        end if;
                     end loop;
                  end if;

                  if Which = 0 then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Pattern),
                        Message => "this case does not belong to the"
                                   & " variant part matched here",
                        Note    => "D77: every arm names one case of the"
                                   & " selected variant part",
                        Related => Syn.Origin (Of_Tree, Subject),
                        Because => "the matched variant part",
                        Into    => Found);
                     Landin.Checking.Refuse
                       (Types.all, Of_Tree, Pattern);
                     Refuse_Bindings (Arm);
                  elsif First (Which) /= Syn.No_Node then
                     Bad.Report
                       (Item    => Bad.Variant_Case_Named_Twice,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Pattern),
                        Message => "this variant case is matched twice",
                        Note    => "D77: an exhaustive match names each"
                                   & " case exactly once",
                        Related => Syn.Origin (Of_Tree, First (Which)),
                        Because => "first matched here",
                        Into    => Found);
                     Landin.Checking.Refuse
                       (Types.all, Of_Tree, Pattern);
                     Refuse_Bindings (Arm);
                  else
                     First (Which) := Pattern;
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Pattern, Ty.Not_Typed);
                     Landin.Checking.Note_Field
                       (Types.all, Of_Tree, Pattern, Which);

                     declare
                        Expected : constant Natural :=
                          Landin.Checking.Variant_Case_Field_Count
                            (Types.all, Wrote, Field, Which);
                        Given : constant Natural :=
                          Syn.Match_Binding_Count (Of_Tree, Arm);
                     begin
                        if Given /= 0 and then Given /= Expected then
                           Bad.Report
                             (Item    => Bad.Type_Mismatch,
                              Source  => Syn.Source_Of (Of_Tree),
                              Where   => Syn.Where (Of_Tree, Pattern),
                              Message => "this arm binds"
                                         & Natural'Image (Given)
                                         & " payload fields, but the case"
                                         & " has" & Natural'Image (Expected),
                              Note    => "D78: parenthesized payload names"
                                         & " are positional and complete",
                              Related => Syn.Origin (Of_Tree, Subject),
                              Because => "the matched variant part",
                              Into    => Found);
                           Refuse_Bindings (Arm);
                        elsif Given /= 0 then
                           for Payload in 1 .. Given loop
                              declare
                                 Binding : constant Syn.Node_Id :=
                                   Syn.Nth_Match_Binding
                                     (Of_Tree, Arm, Payload);
                                 Id : constant Res.Declaration_Id :=
                                   Binding_Id (Binding);
                                 Shape : constant
                                   Landin.Checking.Field_Shape :=
                                     Landin.Checking.Nth_Variant_Case_Field
                                       (Types.all, Wrote, Field, Which,
                                        Payload);
                              begin
                                 if Shape.Kind =
                                      Landin.Checking.Scalar_Field
                                 then
                                    Landin.Checking.Settle
                                      (Types.all, Id, Shape.Element);
                                    Landin.Checking.Note
                                      (Types.all, Of_Tree, Binding,
                                       Shape.Element);
                                 else
                                    Landin.Checking.Settle
                                      (Types.all, Id, Ty.Fixed_Array);
                                    Landin.Checking.Note
                                      (Types.all, Of_Tree, Binding,
                                       Ty.Fixed_Array);
                                    Landin.Checking.Note_Array
                                      (Types.all, Id,
                                       Shape.Length, Shape.Element);
                                 end if;
                              end;
                           end loop;
                        end if;
                     end;
                  end if;

                  Check_Block
                    (Of_Tree, Syn.Body_Of (Of_Tree, Arm), Returns);
               end;
            end loop;

            for Which in First'Range loop
               if First (Which) = Syn.No_Node then
                  declare
                     Missing : constant Syn.Node_Id :=
                       Syn.Nth_Case (Body_Tree.all, Part, Which);
                  begin
                     Bad.Report
                       (Item    => Bad.Variant_Case_Not_Matched,
                        Source  => Syn.Source_Of (Of_Tree),
                        Where   => Syn.Where (Of_Tree, Subject),
                        Message => "this match has no arm for `"
                                   & Spelled
                                       (Syn.Name (Body_Tree.all, Missing))
                                   & "`",
                        Note    => "D77: matching a variant part is"
                                   & " exhaustive",
                        Into    => Found);
                  end;
               end if;
            end loop;
         end;
      end Check_Match;

      procedure Check_Statement
        (Of_Tree : Syn.Tree; Node : Syn.Node_Id; Returns : Ty.Type_Kind) is
      begin
         case Syn.Kind (Of_Tree, Node) is
            when Syn.Binding =>
               declare
                  Value : constant Syn.Node_Id :=
                    Syn.Value_Of (Of_Tree, Node);
                  --  D21's direct-name form is checked here for both a
                  --  module binding and a binding inside a body; the latter
                  --  is always local.
                  Wants : constant Ty.Type_Kind :=
                    Declared_As_Node (Of_Tree, Node);
               begin
                  if Value = Syn.No_Node or else Wants = Ty.Ill_Typed then
                     --  The declaration has already explained why this value
                     --  form is refused; checking the initializer as another
                     --  whole-array value would only repeat L0304.
                     null;
                  elsif Wants = Ty.Undecided then
                     --  [0050]: the inferred form takes the value's type,
                     --  and [0200] settles a literal that has none.  D21's
                     --  narrow array case reads the shape from a direct
                     --  storage name without making array names general
                     --  values.  D25/D26's literal was already given its
                     --  finite shape and scalar context by Infer; D33/D35 do
                     --  the same for a counted local or module repetition.
                     --  Checking either
                     --  here applies its contextual element boundary.
                     --  Every other form still goes through Synthesise and
                     --  keeps its existing refusal.
                     declare
                        Inferred_Array : constant Boolean :=
                          Syn.Kind (Of_Tree, Value)
                            in Syn.Array_Literal | Syn.Array_Repetition
                          and then Landin.Checking.Type_Of
                                     (Types.all, Of_Tree, Value)
                                   = Ty.Fixed_Array;
                        Inferred_Struct : constant Boolean :=
                          Is_Direct_Binding_Name (Of_Tree, Value)
                          and then Landin.Checking.Type_Of
                            (Types.all, Of_Tree, Value) = Ty.Aggregate;
                        Inferred_Construction : constant Boolean :=
                          Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
                          and then Syn.Constructed_Type (Of_Tree, Value)
                                     /= Syn.No_Node
                          and then Landin.Checking.Type_Of
                            (Types.all, Of_Tree, Value) = Ty.Aggregate;
                     begin
                        if Inferred_Construction then
                           Check_Struct_Literal
                             (Of_Tree, Value,
                              Landin.Checking.Body_Of
                                (Types.all, Of_Tree, Value),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Inferred_Array
                          and then Syn.Kind (Of_Tree, Value)
                                   = Syn.Array_Literal
                        then
                           Check_Array_Literal
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Value),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Value),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Inferred_Array then
                           Check_Array_Repetition
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Value),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Value),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        else
                           declare
                              Got : constant Ty.Type_Kind :=
                                (if Is_Direct_Array_Name (Of_Tree, Value)
                                      or else Inferred_Struct
                                 then Selected_From (Of_Tree, Value)
                                 else Synthesise (Of_Tree, Value));
                           begin
                              if Got = Ty.Untyped_Integer then
                                 Commit_To
                                   (Of_Tree, Value, Ty.Default_Integer);
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
                        end if;
                     end;
                  elsif Wants = Ty.Aggregate then
                     declare
                        Written : constant Syn.Node_Id :=
                          Syn.Declared_Type (Of_Tree, Node);
                     begin
                        if Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
                        then
                           declare
                              Expected : constant Res.Declaration_Id :=
                                Landin.Checking.Body_Of
                                  (Types.all, Of_Tree, Written);
                           begin
                              if Construction_Agrees
                                (Of_Tree, Value, Expected,
                                 Syn.Origin (Of_Tree, Node),
                                 "the type declared here")
                              then
                                 Check_Struct_Literal
                                   (Of_Tree, Value, Expected,
                                    Static_Image =>
                                      not Is_Local_Binding (Of_Tree, Node));
                              end if;
                           end;
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                        then
                           --  D57: the written nominal type is the literal's
                           --  only context.  Carry both its aggregate kind and
                           --  [0710] body without making `zeroed` general.
                           Landin.Checking.Note
                             (Types.all, Of_Tree, Value, Ty.Aggregate);
                           Landin.Checking.Note_Body
                             (Types.all, Of_Tree, Value,
                              Landin.Checking.Body_Of
                                (Types.all, Of_Tree, Written));
                        else
                           --  D55: a direct storage name is the other
                           --  contextual aggregate initializer.  Identity
                           --  remains [0710]'s body declaration through
                           --  aliases on either side.
                           declare
                              Got : constant Ty.Type_Kind :=
                                (if Is_Direct_Binding_Name (Of_Tree, Value)
                                      or else Syn.Kind (Of_Tree, Value)
                                                = Syn.Member_Selection
                                 then Selected_From (Of_Tree, Value)
                                 else Synthesise (Of_Tree, Value));
                           begin
                              if Got = Ty.Ill_Typed then
                                 null;
                              elsif Got /= Ty.Aggregate
                                or else Landin.Checking.Body_Of
                                  (Types.all, Of_Tree, Written)
                                    /= Landin.Checking.Body_Of
                                      (Types.all, Of_Tree, Value)
                              then
                                 Bad.Report
                                   (Item    => Bad.Type_Mismatch,
                                    Source  => Syn.Source_Of (Of_Tree),
                                    Where   => Syn.Where (Of_Tree, Value),
                                    Message => "this is not a value of the"
                                               & " struct type written here",
                                    Note    => "[0710]: two structs are one"
                                               & " type when one declaration"
                                               & " wrote both, and never"
                                               & " otherwise",
                                    Related => Syn.Origin (Of_Tree, Node),
                                    Because => "the type declared here",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              end if;
                           end;
                        end if;
                     end;
                  elsif Wants = Ty.Fixed_Array then
                     declare
                        Written : constant Syn.Node_Id :=
                          Syn.Declared_Type (Of_Tree, Node);
                     begin
                        if Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                        then
                           --  D27: this contextual literal denotes the absent
                           --  static image.  Its written array type supplies
                           --  the shape without making `zeroed` a value that
                           --  can appear in any other expression position.
                           Landin.Checking.Note
                             (Types.all, Of_Tree, Value, Ty.Fixed_Array);
                           Landin.Checking.Note_Array
                             (Types.all, Of_Tree, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Written));
                        elsif Syn.Kind (Of_Tree, Value)
                                = Syn.Mixed_Array_Repetition
                        then
                           --  D36/D38: an explicitly typed local or module
                           --  initializer gives a mixed prefix its shape; a
                           --  module image additionally requires static folds.
                           Check_Mixed_Array_Repetition
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Written),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Array_Repetition
                        then
                           --  D34: the written nonzero shape supplies a count
                           --  when `of` has none.  At module scope the one
                           --  scalar expression also takes D24's static-fold
                           --  boundary.
                           Check_Array_Repetition
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Written),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        elsif Syn.Kind (Of_Tree, Value) = Syn.Array_Literal
                        then
                           --  D23 for a local, D24 for a module binding:
                           --  the written array type supplies the exact
                           --  count and scalar context for every element.
                           --  Check_Module_Value applies [1940] to the
                           --  literal as it does for any other module
                           --  value, so a runtime element is refused there.
                           Check_Array_Literal
                             (Of_Tree, Node, Value,
                              Landin.Checking.Array_Length
                                (Types.all, Of_Tree, Written),
                              Landin.Checking.Array_Element
                                (Types.all, Of_Tree, Written),
                              Static_Image =>
                                not Is_Local_Binding (Of_Tree, Node));
                        else
                           --  D21: the other initializer form is a
                           --  whole-array copy from a storage name, so the
                           --  identity check is D17's as an assignment's is.
                           --  Selected_From keeps that one direct name out
                           --  of the general-value refusal.
                           declare
                              Admitted : constant Boolean :=
                                Syn.Kind (Of_Tree, Value)
                                  = Syn.Member_Selection
                                and then Admit_Array_Field (Of_Tree, Value);
                              Got : constant Ty.Type_Kind :=
                                (if Is_Direct_Binding_Name (Of_Tree, Value)
                                      or else Admitted
                                 then Selected_From (Of_Tree, Value)
                                 else Synthesise (Of_Tree, Value));
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
                                    Message => "this is not an array of the"
                                               & " type written here",
                                    Note    => "D17: an array's length and"
                                               & " element type are its"
                                               & " identity",
                                    Related => Syn.Origin (Of_Tree, Node),
                                    Because => "the type declared here",
                                    Into    => Found);
                                 Landin.Checking.Refuse
                                   (Types.all, Of_Tree, Value);
                              end if;
                           end;
                        end if;
                     end;
                  elsif Wants in Ty.Scalar_Name
                    and then Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                  then
                     --  D39/D40: a written module or local scalar type is the
                     --  scalar context for `zeroed`; Type_At has already
                     --  resolved an alias to the enabled scalar it denotes.
                     --  Inference, assignment and general expressions still
                     --  reach the ordinary refusal.
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Value, Wants);
                  else
                     Require
                       (Of_Tree, Value, Wants, Syn.Origin (Of_Tree, Node),
                        "the type declared here");
                  end if;
               end;

            when Syn.Assignment =>
               --  D76 gives a directly selected variant part one contextual
               --  destination form.  It is intercepted before ordinary
               --  selection synthesis (which correctly keeps the part out
               --  of general values), while Check_Place still owns root
               --  mutability and runs before the case is inspected.
               if Admit_Variant_Field
                    (Of_Tree, Syn.Target_Of (Of_Tree, Node))
               then
                  declare
                     Place : constant Syn.Node_Id :=
                       Syn.Target_Of (Of_Tree, Node);
                     Value : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree, Node);
                     Base : constant Syn.Node_Id :=
                       Syn.Target_Of (Of_Tree, Place);
                  begin
                     Check_Place
                       (Of_Tree, Place, Stepping => False,
                        Variant_Context => True);
                     if Landin.Checking.Type_Of
                          (Types.all, Of_Tree, Place) = Ty.Ill_Typed
                     then
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree, Value);
                     else
                        Check_Variant_Value
                          (Of_Tree, Place, Value,
                           Landin.Checking.Body_Of
                             (Types.all, Of_Tree, Base),
                           Positive
                             (Landin.Checking.Field_Index
                                (Types.all, Of_Tree, Place)));
                     end if;
                  end;
                  return;
               end if;

               --  D49 supplies the fixed-array shape for a complete `zeroed`
               --  assignment.  D50 additionally recognizes a direct array
               --  name or a selection as copy syntax, D52 recognizes D29's
               --  literal syntax, and D53 recognizes D32/D37 repetition.
               --  The source selection is not typed until Check_Place accepts
               --  the destination, so destination diagnostics remain first
               --  and alone.
               if Syn.Kind (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                    in Syn.Zeroed_Literal | Syn.Array_Literal
                       | Syn.Array_Repetition | Syn.Mixed_Array_Repetition
                       | Syn.Call
                 or else Is_Direct_Array_Name
                   (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                 or else Syn.Kind
                   (Of_Tree, Syn.Value_Of (Of_Tree, Node))
                    = Syn.Member_Selection
               then
                  if Admit_Array_Field
                       (Of_Tree, Syn.Target_Of (Of_Tree, Node))
                  then
                     null;
                  end if;
               end if;

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
                  --  D50 may put a selection on the source side.  Since the
                  --  destination owns this refusal, mark that unvisited
                  --  source ill-typed as well: the later flow walk must not
                  --  fall back from an undecided selection to a whole read
                  --  of its local aggregate base and add L0302.
                  Landin.Checking.Refuse
                    (Types.all, Of_Tree, Syn.Value_Of (Of_Tree, Node));
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
                  if Wants = Ty.Aggregate then
                     if Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal then
                        declare
                           Expected : constant Res.Declaration_Id :=
                             Landin.Checking.Body_Of
                               (Types.all, Of_Tree, Place);
                        begin
                           if Construction_Agrees
                             (Of_Tree, Value, Expected,
                              Syn.Origin (Of_Tree, Place),
                              "the place written here")
                           then
                              Check_Struct_Literal
                                (Of_Tree, Value, Expected,
                                 Static_Image => False);
                           end if;
                        end;
                     elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal then
                        --  D58: a direct mutable struct place supplies both
                        --  [0540]'s aggregate context and [0710]'s body.  The
                        --  literal has no source value and reads nothing.
                        Landin.Checking.Note
                          (Types.all, Of_Tree, Value, Ty.Aggregate);
                        Landin.Checking.Note_Body
                          (Types.all, Of_Tree, Value,
                           Landin.Checking.Body_Of
                             (Types.all, Of_Tree, Place));
                     else
                        --  [0710]: a whole struct is copied into a place of
                        --  the same type.  A copy is the one expression
                        --  position a struct may stand in, because the bytes
                        --  go straight between places without a value.
                        declare
                           Got : constant Ty.Type_Kind :=
                             (if Is_Direct_Binding_Name (Of_Tree, Value)
                                   or else Syn.Kind (Of_Tree, Value)
                                             = Syn.Member_Selection
                              then Selected_From (Of_Tree, Value)
                              else Synthesise (Of_Tree, Value));
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
                                 Note    => "[0710]: two structs are one"
                                            & " type when one declaration"
                                            & " wrote both, and never"
                                            & " otherwise",
                                 Related => Syn.Origin (Of_Tree, Place),
                                 Because => "the place written here",
                                 Into    => Found);
                              Landin.Checking.Refuse
                                (Types.all, Of_Tree, Value);
                           end if;
                        end;
                     end if;

                     return;
                  end if;

                  --  D20 copies an array straight from one storage place to
                  --  another.  D29's literal and D30's `zeroed` are
                  --  contextual: the destination's D17 shape supplies their
                  --  count and scalar element type without making either a
                  --  general value.
                  if Wants = Ty.Fixed_Array then
                     if Syn.Kind (Of_Tree, Value)
                          = Syn.Mixed_Array_Repetition
                     then
                        --  D37 gives this contextual mixed form the complete
                        --  shape of its mutable fixed-array destination.
                        Check_Mixed_Array_Repetition
                          (Of_Tree, Place, Value,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element
                             (Types.all, Of_Tree, Place),
                           Static_Image => False);
                     elsif Syn.Kind (Of_Tree, Value)
                             = Syn.Array_Repetition
                     then
                        Check_Array_Repetition
                          (Of_Tree, Place, Value,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element
                             (Types.all, Of_Tree, Place),
                           Static_Image => False);
                     elsif Syn.Kind (Of_Tree, Value) = Syn.Array_Literal then
                        Check_Array_Literal
                          (Of_Tree, Place, Value,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element
                             (Types.all, Of_Tree, Place),
                           Static_Image => False);
                     elsif Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                     then
                        Landin.Checking.Note
                          (Types.all, Of_Tree, Value, Ty.Fixed_Array);
                        Landin.Checking.Note_Array
                          (Types.all, Of_Tree, Value,
                           Landin.Checking.Array_Length
                             (Types.all, Of_Tree, Place),
                           Landin.Checking.Array_Element
                             (Types.all, Of_Tree, Place));
                     else
                        declare
                           Admitted : constant Boolean :=
                             (Syn.Kind (Of_Tree, Value)
                                = Syn.Member_Selection
                              and then Admit_Array_Field (Of_Tree, Value));
                           Got : constant Ty.Type_Kind :=
                             (if Admitted
                                   or else Is_Direct_Binding_Name
                                     (Of_Tree, Value)
                              then Selected_From (Of_Tree, Value)
                              else Synthesise (Of_Tree, Value));
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
                                 Note    => "D17: an array's length and"
                                            & " element type are its identity",
                                 Related => Syn.Origin (Of_Tree, Place),
                                 Because => "the place written here",
                                 Into    => Found);
                              Landin.Checking.Refuse
                                (Types.all, Of_Tree, Value);
                           end if;
                        end;
                     end if;

                     return;
                  end if;

                  --  D41--D43/D62: a mutable scalar binding, an admitted
                  --  scalar subobject, or a direct named return supplies the
                  --  contextual type for `zeroed`.  Check_Place has already
                  --  resolved aliases and refused immutable or invalid
                  --  destinations.
                  if Wants in Ty.Scalar_Name
                    and then Is_Zeroed_Scalar_Place (Of_Tree, Place)
                    and then Syn.Kind (Of_Tree, Value) = Syn.Zeroed_Literal
                  then
                     Landin.Checking.Note
                       (Types.all, Of_Tree, Value, Wants);
                  else
                     Require
                       (Of_Tree, Value, Wants, Syn.Origin (Of_Tree, Place),
                        "the place written here");
                  end if;
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

            when Syn.Match_Statement =>
               Check_Match (Of_Tree, Node, Returns);

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

            --  D31 measures the literal's syntax.  Its elements are checked
            --  for one scalar shape but are not module values to be folded.
            when Syn.Len_Of =>
               return True;

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
         Written : constant Syn.Node_Id :=
           Syn.Declared_Type (Of_Tree, Node);
         Contextual_Image : constant Boolean :=
           (Written /= Syn.No_Node
            and then Type_At (Of_Tree, Written) = Ty.Fixed_Array)
           or else
             (Value /= Syn.No_Node
              and then Syn.Kind (Of_Tree, Value)
                       in Syn.Array_Literal | Syn.Array_Repetition
                          | Syn.Mixed_Array_Repetition
                          | Syn.Member_Selection
              and then Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Value) = Ty.Fixed_Array);
         --  D66 checks each scalar field inside a contextual module struct
         --  literal at the literal boundary.  Do not send its labelled run
         --  through the generic subtree refusal a second time.
         Module_Struct_Literal : constant Boolean :=
           Value /= Syn.No_Node
           and then Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
           and then
             ((Written /= Syn.No_Node
               and then Type_At (Of_Tree, Written) = Ty.Aggregate)
              or else Landin.Checking.Type_Of
                (Types.all, Of_Tree, Value) = Ty.Aggregate);

         procedure Refuse_Unreadable_Subtree (Where : Syn.Node_Id);

         procedure Refuse_Unreadable_Subtree (Where : Syn.Node_Id) is
         begin
            if Where = Syn.No_Node then
               return;
            end if;

            declare
               What : constant String :=
                 (case Syn.Kind (Of_Tree, Where) is
                     when Syn.Member_Selection => "a field selection",
                     when Syn.Element_Index    => "an array index",
                     when others               => "");
            begin
               --  D31's operand is checked for one scalar shape, but its
               --  expressions are not read to form the compile-time count.
               if Syn.Kind (Of_Tree, Where) = Syn.Len_Of then
                  return;
               end if;

               if What /= "" then
                  Bad.Report
                    (Item    => Bad.Not_Known_At_Compile_Time,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Where),
                     Message => What & " has no static module value in this"
                                & " compiler",
                     Note    => "[1940]: a module initializer is read at"
                                & " compile time, before any storage can be"
                                & " selected",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Where);
                  return;
               end if;

               for Position in 1 .. Syn.Slot_Count (Of_Tree, Where) loop
                  Refuse_Unreadable_Subtree
                    (Syn.Slot (Of_Tree, Where, Position));
               end loop;
            end;
         end Refuse_Unreadable_Subtree;
      begin
         --  A contextual initializer boundary already owns a refused binding
         --  or value.  Every Declared_As_Node refusal marks the written type,
         --  while D51's selected field marks the value; [1940] must not add a
         --  second report after either refusal.
         if (Written /= Syn.No_Node
             and then Landin.Checking.Type_Of
                        (Types.all, Of_Tree, Written) = Ty.Ill_Typed)
           or else
             (Value /= Syn.No_Node
              and then Landin.Checking.Type_Of (Types.all, Of_Tree, Value)
                         = Ty.Ill_Typed)
         then
            return;
         end if;

         --  D24 gives array-literal elements their own more specific boundary.
         --  Scalar module values still follow [1940]: selecting storage is not
         --  a compile-time scalar image, even beneath an otherwise foldable
         --  operator.
         if Value /= Syn.No_Node
           and then not Contextual_Image
           and then not Module_Struct_Literal
         then
            Refuse_Unreadable_Subtree (Value);
         end if;

         --  D66's contextual literal walk owns per-field static exclusions
         --  and unknown-value reports.  It runs in Check_Statement just
         --  after this generic module boundary.
         if Module_Struct_Literal then
            return;
         end if;

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

         --  D72: unlike a bare inferred literal, construction supplies the
         --  nominal body before the declaration is settled.  The field walk
         --  remains contextual and runs in Check_Statement.
         if Res.Sort_Of (Meanings.all, Id)
              in Res.Local_Binding | Res.Module_Binding
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Struct_Literal
           and then Syn.Constructed_Type (Of_Tree.all, Value) /= Syn.No_Node
         then
            declare
               Wrote : constant Res.Declaration_Id :=
                 Construction_Body (Of_Tree.all, Value);
            begin
               if Wrote = Res.No_Declaration then
                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
               else
                  Landin.Checking.Note
                    (Types.all, Of_Tree.all, Value, Ty.Aggregate);
                  Landin.Checking.Note_Body
                    (Types.all, Of_Tree.all, Value, Wrote);
                  Landin.Checking.Note_Body (Types.all, Id, Wrote);
                  Landin.Checking.Settle (Types.all, Id, Ty.Aggregate);
               end if;
            end;
            return;
         end if;

         --  [0530]: a nonempty literal in an inferred binding supplies D17's
         --  length and takes its scalar element type from the first element.
         --  [0200] gives an otherwise untyped integer expression its default
         --  context; that settled scalar then checks every later element.
         --  D25 uses the shape for a local source-order initializer; D26 uses
         --  the same shape for D24's separate [1940] module image boundary.
         if Res.Sort_Of (Meanings.all, Id)
              in Res.Local_Binding | Res.Module_Binding
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Array_Literal
         then
            declare
               Count : constant Landin.Checking.Element_Count :=
                 Landin.Checking.Element_Count
                   (Syn.Element_Count (Of_Tree.all, Value));
               First : constant Syn.Node_Id :=
                 Syn.Nth_Element (Of_Tree.all, Value, 1);
               Got : constant Ty.Type_Kind :=
                 Synthesise (Of_Tree.all, First);
               Element : Ty.Scalar_Name;
            begin
               if Got = Ty.Untyped_Integer then
                  Element := Ty.Default_Integer;
                  Commit_To (Of_Tree.all, First, Element);
               elsif Got in Ty.Scalar_Name then
                  Element := Ty.Scalar_Name (Got);
               else
                  if Got = Ty.No_Value then
                     Bad.Report
                       (Item    => Bad.Type_Mismatch,
                        Source  => Syn.Source_Of (Of_Tree.all),
                        Where   => Syn.Where (Of_Tree.all, First),
                        Message => "this hands back nothing, so it cannot"
                                   & " supply an array element type",
                        Note    => "[0530]: the literal supplies one scalar"
                                   & " element type for the inferred array",
                        Related => Syn.Origin (Of_Tree.all, Node),
                        Because => "this inferred binding",
                        Into    => Found);
                  end if;

                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  return;
               end if;

               declare
                  Element_Bytes : constant Ty.Magnitude :=
                    Ty.Magnitude
                      (Landin.Targets.Bytes
                         (Ty.Storage_Size (Element, Facts)));
                  Maximum_Bytes : constant Ty.Magnitude :=
                    Ty.Magnitude
                      (Landin.Targets.Maximum_Object_Size (Facts));
               begin
                  if Element_Bytes /= 0
                    and then Ty.Magnitude (Count)
                               > Maximum_Bytes / Element_Bytes
                  then
                     Bad.Report
                       (Item    => Bad.Literal_Out_Of_Range,
                        Source  => Syn.Source_Of (Of_Tree.all),
                        Where   => Syn.Where (Of_Tree.all, Value),
                        Message => "this inferred array is larger than the"
                                   & " target can address",
                        Note    => "D18: an array's byte extent must fit the"
                                   & " target's usize",
                        Into    => Found);
                     Landin.Checking.Refuse (Types.all, Of_Tree.all, Value);
                     Landin.Checking.Settle
                       (Types.all, Id, Ty.Ill_Typed);
                     return;
                  end if;
               end;

               Landin.Checking.Note
                 (Types.all, Of_Tree.all, Value, Ty.Fixed_Array);
               Landin.Checking.Note_Array
                 (Types.all, Of_Tree.all, Value, Count, Element);
               Landin.Checking.Note_Array
                 (Types.all, Id, Count, Element);
               Landin.Checking.Settle (Types.all, Id, Ty.Fixed_Array);

               for Position in 2 .. Syn.Element_Count (Of_Tree.all, Value) loop
                  Require
                    (Of_Tree.all,
                     Syn.Nth_Element (Of_Tree.all, Value, Position), Element,
                     Syn.Origin (Of_Tree.all, Node),
                     "the first inferred array element");
               end loop;
            end;

            return;
         end if;

         --  D33/D35: a counted repetition directly initializing an inferred
         --  local or module binding supplies D17's length and takes its scalar
         --  element type from its
         --  one expression.  Like D25, an untyped integer takes [0200]'s
         --  default; unlike a literal, no source run needs a common context.
         --  A zero count remains deferred with [0580]'s source-level empty
         --  array decision even though the internal shape can represent one.
         if Res.Sort_Of (Meanings.all, Id)
              in Res.Local_Binding | Res.Module_Binding
           and then Syn.Kind (Of_Tree.all, Value) = Syn.Array_Repetition
           and then Syn.Repetition_Count (Of_Tree.all, Value) /= Syn.No_Node
         then
            declare
               Count_Node : constant Syn.Node_Id :=
                 Syn.Repetition_Count (Of_Tree.all, Value);
               Repeated : constant Syn.Node_Id :=
                 Syn.Repeated_Element (Of_Tree.all, Value);
               Snap : constant Landin.Source.Snapshot :=
                 Source (Context, Syn.Source_Of (Of_Tree.all));
               Text : constant String :=
                 Landin.Source.Slice
                   (Snap, Syn.Digit_Span (Of_Tree.all, Count_Node));
               Count_Value : Ty.Magnitude;
               Overflowed  : Boolean;
            begin
               Ty.Evaluate
                 (Text, Syn.Base (Of_Tree.all, Count_Node),
                  Count_Value, Overflowed);

               if Overflowed then
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Syn.Source_Of (Of_Tree.all),
                     Where   => Syn.Where (Of_Tree.all, Count_Node),
                     Message => "this is more elements than an array may have",
                     Note    => "D18: an array's byte extent must fit the"
                                & " target's usize",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree.all, Value);
                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  return;
               elsif Count_Value = 0 then
                  Bad.Report
                    (Item    => Bad.Unsupported_Use,
                     Source  => Syn.Source_Of (Of_Tree.all),
                     Where   => Syn.Where (Of_Tree.all, Count_Node),
                     Message => "inferring a zero-element array is not"
                                & " enabled yet",
                     Refused => Bad.Array_Value,
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree.all, Value);
                  Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                  return;
               end if;

               declare
                  Count : constant Landin.Checking.Element_Count :=
                    Landin.Checking.Element_Count (Count_Value);
                  Got : constant Ty.Type_Kind :=
                    Synthesise (Of_Tree.all, Repeated);
                  Element : Ty.Scalar_Name;
               begin
                  if Got = Ty.Untyped_Integer then
                     Element := Ty.Default_Integer;
                     Commit_To (Of_Tree.all, Repeated, Element);
                  elsif Got in Ty.Scalar_Name then
                     Element := Ty.Scalar_Name (Got);
                  else
                     if Got = Ty.No_Value then
                        Bad.Report
                          (Item    => Bad.Type_Mismatch,
                           Source  => Syn.Source_Of (Of_Tree.all),
                           Where   => Syn.Where (Of_Tree.all, Repeated),
                           Message => "this hands back nothing, so it cannot"
                                      & " supply an array element type",
                           Note    => "D33: repetition supplies one scalar"
                                      & " element type for the inferred array",
                           Related => Syn.Origin (Of_Tree.all, Node),
                           Because => "this inferred binding",
                           Into    => Found);
                     end if;

                     Landin.Checking.Settle (Types.all, Id, Ty.Ill_Typed);
                     return;
                  end if;

                  declare
                     Element_Bytes : constant Ty.Magnitude :=
                       Ty.Magnitude
                         (Landin.Targets.Bytes
                            (Ty.Storage_Size (Element, Facts)));
                     Maximum_Bytes : constant Ty.Magnitude :=
                       Ty.Magnitude
                         (Landin.Targets.Maximum_Object_Size (Facts));
                  begin
                     if Element_Bytes /= 0
                       and then Count_Value > Maximum_Bytes / Element_Bytes
                     then
                        Bad.Report
                          (Item    => Bad.Literal_Out_Of_Range,
                           Source  => Syn.Source_Of (Of_Tree.all),
                           Where   => Syn.Where (Of_Tree.all, Value),
                           Message => "this inferred array is larger than the"
                                      & " target can address",
                           Note    => "D18: an array's byte extent must fit"
                                      & " the target's usize",
                           Into    => Found);
                        Landin.Checking.Refuse
                          (Types.all, Of_Tree.all, Value);
                        Landin.Checking.Settle
                          (Types.all, Id, Ty.Ill_Typed);
                        return;
                     end if;
                  end;

                  Landin.Checking.Note
                    (Types.all, Of_Tree.all, Value, Ty.Fixed_Array);
                  Landin.Checking.Note_Array
                    (Types.all, Of_Tree.all, Value, Count, Element);
                  Landin.Checking.Note_Array
                    (Types.all, Id, Count, Element);
                  Landin.Checking.Settle
                    (Types.all, Id, Ty.Fixed_Array);
               end;
            end;

            return;
         end if;

         declare
            --  D21 infers D17's shape from a direct storage name for a local
            --  or module binding.  D56/D61 admit an aggregate source only
            --  after carrying its nominal body identity.  Settling an
            --  untouched source is intentional for a forward module name;
            --  the Underway guard preserves an inferred cycle's single
            --  report.  A type declaration is a name but owns no storage.
            Named_Storage : constant Boolean :=
              Res.Sort_Of (Meanings.all, Id)
                in Res.Local_Binding | Res.Module_Binding
              and then Syn.Kind (Of_Tree.all, Value) = Syn.Name_Reference
              and then Res.Verdict_Of (Meanings.all, Of_Tree.all, Value)
                       = Res.Bound
              and then Res.Sort_Of
                (Meanings.all,
                 Res.Bound_To (Meanings.all, Of_Tree.all, Value))
                  in Res.Local_Binding | Res.Module_Binding;
            Named : constant Res.Declaration_Id :=
              (if Named_Storage
               then Res.Bound_To (Meanings.all, Of_Tree.all, Value)
               else Res.No_Declaration);
            Named_Type : constant Ty.Type_Kind :=
              (if Named_Storage
                    and then Landin.Checking.State_Of (Types.all, Named)
                               /= Landin.Checking.Underway
               then Settled_Type (Named)
               else Ty.Ill_Typed);
            Direct_Name : constant Boolean :=
              Named_Storage and then Named_Type = Ty.Fixed_Array;
            Direct_Field : constant Boolean :=
              Syn.Kind (Of_Tree.all, Value) = Syn.Member_Selection
              and then
                (Syn.Kind
                   (Of_Tree.all, Syn.Target_Of (Of_Tree.all, Value))
                   = Syn.Name_Reference
                 or else Res.Sort_Of (Meanings.all, Id) = Res.Local_Binding)
              and then Admit_Array_Field (Of_Tree.all, Value);
            Direct_Child : constant Boolean :=
              not Direct_Field
              and then Res.Sort_Of (Meanings.all, Id) = Res.Local_Binding
              and then Syn.Kind (Of_Tree.all, Value)
                         = Syn.Member_Selection
              and then Syn.Kind
                (Of_Tree.all, Syn.Target_Of (Of_Tree.all, Value))
                  = Syn.Name_Reference
              and then Selected_From (Of_Tree.all, Value) = Ty.Aggregate;
            Direct_Struct : constant Boolean :=
              (Named_Storage
               and then Named_Type = Ty.Aggregate
               and then Landin.Checking.Body_Of (Types.all, Named)
                          /= Res.No_Declaration)
              or else Direct_Child;
            Direct_Source : constant Boolean :=
              Direct_Name or else Direct_Field or else Direct_Struct;
            Got : constant Ty.Type_Kind :=
              (if Direct_Source
               then Selected_From (Of_Tree.all, Value)
               else Synthesise (Of_Tree.all, Value));
            Direct_Array : constant Boolean :=
              (Direct_Name or else Direct_Field)
              and then Got = Ty.Fixed_Array;
         begin
            if Got = Ty.Untyped_Integer then
               Commit_To (Of_Tree.all, Value, Ty.Default_Integer);
               Landin.Checking.Settle
                 (Types.all, Id, Ty.Type_Kind (Ty.Default_Integer));
            else
               if Got = Ty.Fixed_Array
                 and then (Direct_Array
                           or else Syn.Kind (Of_Tree.all, Value) = Syn.Call)
               then
                  Landin.Checking.Note_Array
                    (Types.all, Id,
                     Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Value),
                     Landin.Checking.Array_Element
                       (Types.all, Of_Tree.all, Value));
               end if;

               if Got = Ty.Aggregate
                 and then (Direct_Struct
                           or else Syn.Kind (Of_Tree.all, Value) = Syn.Call)
               then
                  --  D56/D61: an inferred aggregate has no written type node
                  --  from which Declared_As can copy [0710]'s identity.  Carry
                  --  the source body's declaration before settling the new
                  --  local or module binding.
                  Landin.Checking.Note_Body
                    (Types.all, Id,
                     Landin.Checking.Body_Of
                       (Types.all, Of_Tree.all, Value));
               end if;

               Landin.Checking.Settle (Types.all, Id, Got);
            end if;
         end;
      end Infer;

      ------------------------------------------------------------
      --  R2.20: every module array or struct image reaches static storage
      ------------------------------------------------------------

      type Image_State is (Unseen, Visiting, Valid, Invalid);
      Image_States : array
        (Res.Declaration_Id'(1)
         .. Res.Declaration_Id (Res.Declaration_Count (Meanings.all)))
        of Image_State := [others => Unseen];

      function Validate_Module_Image
        (Id : Res.Declaration_Id) return Boolean;
      procedure Validate_Module_Images;

      function Validate_Module_Image
        (Id : Res.Declaration_Id) return Boolean
      is
         Of_Tree : constant not null access constant Syn.Tree :=
           Tree_For (Res.Source_Of (Meanings.all, Id));
         Node  : constant Syn.Node_Id := Res.Node_Of (Meanings.all, Id);
         Value : constant Syn.Node_Id := Syn.Value_Of (Of_Tree.all, Node);
      begin
         case Image_States (Id) is
            when Valid =>
               return True;

            when Invalid =>
               return False;

            when Visiting =>
               --  Declaration order chooses the first root, and marking the
               --  entire path Invalid on the way out means this cycle earns
               --  one [1940] report rather than one report per member.
               Bad.Report
                 (Item    => Bad.Not_Known_At_Compile_Time,
                  Source  => Res.Source_Of (Meanings.all, Id),
                  Where   => Syn.Anchor (Of_Tree.all, Node),
                  Message => "the initial image of `"
                             & Spelled (Syn.Name (Of_Tree.all, Node))
                             & "` is worked out from itself",
                  Note    => "[1940]: a chain that comes back to where it"
                             & " began names nothing at all",
                  Into    => Found);
               Image_States (Id) := Invalid;
               return False;

            when Unseen =>
               null;
         end case;

         Image_States (Id) := Visiting;

         --  An omitted initializer is D10's zero image; D24 admits an array
         --  literal terminal image, while D27 and D59 spell array and struct
         --  zero images explicitly.
         --  Refused or mismatched initializer forms are left to their existing
         --  diagnostics rather than producing graph fallout.
         if Value = Syn.No_Node then
            Image_States (Id) := Valid;
            return True;
         end if;

         if Syn.Kind (Of_Tree.all, Value)
              in Syn.Array_Literal | Syn.Zeroed_Literal
         then
            Image_States (Id) := Valid;
            return True;
         end if;

         if Syn.Kind (Of_Tree.all, Value) = Syn.Struct_Literal then
            --  D69 follows a direct module array datum; D71 follows one
            --  directly selected field by way of its containing module
            --  struct.  Follow only well-shaped edges.  Every malformed
            --  label keeps Check_Struct_Literal's diagnostic owner, while
            --  the shared Visiting state owns every array/struct mixture that
            --  comes back to a declaration already on the image path.
            declare
               Wrote : constant Res.Declaration_Id :=
                 Landin.Checking.Body_Of (Types.all, Id);
               Reaches_Image : Boolean := True;
            begin
               if Wrote = Res.No_Declaration
                 or else not Landin.Checking.Has_Layout (Types.all, Wrote)
               then
                  Image_States (Id) := Invalid;
                  return False;
               end if;

               for Position in
                 1 .. Syn.Field_Value_Count (Of_Tree.all, Value)
               loop
                  declare
                     Field : constant Syn.Node_Id :=
                       Syn.Nth_Field_Value
                         (Of_Tree.all, Value, Position);
                     Image_Value : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree.all, Field);
                     Which : constant Natural :=
                       Field_At (Wrote, Syn.Name (Of_Tree.all, Field));
                  begin
                     if Which /= 0
                       and then Landin.Checking.Field_Kind_Of
                         (Types.all, Wrote, Which)
                           = Landin.Checking.Fixed_Array_Field
                       and then Syn.Kind (Of_Tree.all, Image_Value)
                                  = Syn.Name_Reference
                       and then Res.Verdict_Of
                         (Meanings.all, Of_Tree.all, Image_Value)
                           = Res.Bound
                     then
                        declare
                           Source_Id : constant Res.Declaration_Id :=
                             Res.Bound_To
                               (Meanings.all, Of_Tree.all, Image_Value);
                           Edge_Is_Valid : constant Boolean :=
                             Res.Sort_Of (Meanings.all, Source_Id)
                               = Res.Module_Binding
                             and then Landin.Checking.Type_Of
                               (Types.all, Source_Id) = Ty.Fixed_Array
                             and then Landin.Checking.Array_Length
                               (Types.all, Source_Id)
                                 = Landin.Checking.Field_Array_Length
                                     (Types.all, Wrote, Which)
                             and then Landin.Checking.Array_Element
                               (Types.all, Source_Id)
                                 = Landin.Checking.Field_Array_Element
                                     (Types.all, Wrote, Which);
                        begin
                           if Edge_Is_Valid then
                              Reaches_Image :=
                                Validate_Module_Image (Source_Id)
                                and then Reaches_Image;
                           else
                              Reaches_Image := False;
                           end if;
                        end;
                     elsif Which /= 0
                       and then Landin.Checking.Field_Kind_Of
                         (Types.all, Wrote, Which)
                           = Landin.Checking.Fixed_Array_Field
                       and then Syn.Kind (Of_Tree.all, Image_Value)
                                  = Syn.Member_Selection
                     then
                        declare
                           Source : constant Syn.Node_Id :=
                             Syn.Target_Of (Of_Tree.all, Image_Value);
                           Edge_Is_Valid : constant Boolean :=
                             Is_Module_Array_Field
                               (Of_Tree.all, Image_Value,
                                Landin.Checking.Field_Array_Length
                                  (Types.all, Wrote, Which),
                                Landin.Checking.Field_Array_Element
                                  (Types.all, Wrote, Which));
                        begin
                           if Edge_Is_Valid then
                              Reaches_Image :=
                                Validate_Module_Image
                                  (Res.Bound_To
                                     (Meanings.all, Of_Tree.all, Source))
                                and then Reaches_Image;
                           else
                              Reaches_Image := False;
                           end if;
                        end;
                     elsif Which /= 0
                       and then Landin.Checking.Field_Kind_Of
                         (Types.all, Wrote, Which)
                           = Landin.Checking.Variant_Field
                       and then Syn.Kind (Of_Tree.all, Image_Value)
                                  = Syn.Struct_Literal
                       and then Landin.Checking.Type_Of
                         (Types.all, Of_Tree.all, Image_Value)
                           /= Ty.Ill_Typed
                     then
                        declare
                           Body_Tree : constant not null access constant
                             Syn.Tree :=
                               Tree_For
                                 (Res.Source_Of (Meanings.all, Wrote));
                           Body_Node : constant Syn.Node_Id :=
                             Syn.Declared_Type
                               (Body_Tree.all,
                                Res.Node_Of (Meanings.all, Wrote));
                           Part : constant Syn.Node_Id :=
                             Syn.Nth_Field
                               (Body_Tree.all, Body_Node,
                                Positive (Which));
                           Nominal : constant Syn.Node_Id :=
                             Syn.Constructed_Type
                               (Of_Tree.all, Image_Value);
                           Means : constant Res.Declaration_Id :=
                             (if Nominal /= Syn.No_Node
                                and then Res.Verdict_Of
                                  (Meanings.all, Of_Tree.all, Nominal)
                                    = Res.Bound
                              then Res.Bound_To
                                (Meanings.all, Of_Tree.all, Nominal)
                              else Res.No_Declaration);
                           Selected : Natural := 0;
                        begin
                           if Means /= Res.No_Declaration
                             and then Res.Sort_Of (Meanings.all, Means)
                               = Res.Case_Name
                           then
                              for Candidate in
                                1 .. Syn.Case_Count (Body_Tree.all, Part)
                              loop
                                 if Res.Source_Of (Meanings.all, Means)
                                      = Syn.Source_Of (Body_Tree.all)
                                   and then Res.Node_Of (Meanings.all, Means)
                                     = Syn.Nth_Case
                                         (Body_Tree.all, Part, Candidate)
                                 then
                                    Selected := Candidate;
                                    exit;
                                 end if;
                              end loop;
                           end if;

                           if Selected /= 0 then
                              declare
                                 Case_Node : constant Syn.Node_Id :=
                                   Syn.Nth_Case
                                     (Body_Tree.all, Part, Selected);
                              begin
                                 for Payload_Position in
                                   1 .. Syn.Field_Value_Count
                                          (Of_Tree.all, Image_Value)
                                 loop
                                    declare
                                       Label : constant Syn.Node_Id :=
                                         Syn.Nth_Field_Value
                                           (Of_Tree.all, Image_Value,
                                            Payload_Position);
                                       Payload : Natural := 0;
                                       Given : constant Syn.Node_Id :=
                                         Syn.Value_Of (Of_Tree.all, Label);
                                    begin
                                       for Candidate in
                                         1 .. Syn.Payload_Field_Count
                                                (Body_Tree.all, Case_Node)
                                       loop
                                          if Syn.Name (Of_Tree.all, Label)
                                            = Syn.Name
                                                (Body_Tree.all,
                                                 Syn.Nth_Payload_Field
                                                   (Body_Tree.all,
                                                    Case_Node, Candidate))
                                          then
                                             Payload := Candidate;
                                             exit;
                                          end if;
                                       end loop;

                                       if Payload = 0 then
                                          Reaches_Image := False;
                                       else
                                          declare
                                             Shape : constant
                                               Landin.Checking.Field_Shape :=
                                                 Landin.Checking
                                                   .Nth_Variant_Case_Field
                                                   (Types.all, Wrote,
                                                    Positive (Which),
                                                    Positive (Selected),
                                                    Positive (Payload));
                                          begin
                                             if Shape.Kind =
                                                  Landin.Checking
                                                    .Fixed_Array_Field
                                               and then Syn.Kind
                                                 (Of_Tree.all, Given)
                                                   = Syn.Name_Reference
                                               and then Res.Verdict_Of
                                                 (Meanings.all, Of_Tree.all,
                                                  Given) = Res.Bound
                                             then
                                                declare
                                                   Source_Id : constant
                                                     Res.Declaration_Id :=
                                                       Res.Bound_To
                                                         (Meanings.all,
                                                          Of_Tree.all,
                                                          Given);
                                                   Edge_Is_Valid : constant
                                                     Boolean :=
                                                       Res.Sort_Of
                                                         (Meanings.all,
                                                          Source_Id)
                                                           = Res.Module_Binding
                                                       and then
                                                         Landin.Checking
                                                           .Type_Of
                                                           (Types.all,
                                                            Source_Id)
                                                           = Ty.Fixed_Array
                                                       and then
                                                         Landin.Checking
                                                           .Array_Length
                                                           (Types.all,
                                                            Source_Id)
                                                           = Shape.Length
                                                       and then
                                                         Landin.Checking
                                                           .Array_Element
                                                           (Types.all,
                                                            Source_Id)
                                                           = Shape.Element;
                                                begin
                                                   if Edge_Is_Valid then
                                                      Reaches_Image :=
                                                        Validate_Module_Image
                                                          (Source_Id)
                                                        and then
                                                          Reaches_Image;
                                                   else
                                                      Reaches_Image := False;
                                                   end if;
                                                end;
                                             elsif Shape.Kind =
                                                     Landin.Checking
                                                       .Fixed_Array_Field
                                               and then Syn.Kind
                                                 (Of_Tree.all, Given)
                                                   = Syn.Member_Selection
                                             then
                                                declare
                                                   Source : constant
                                                     Syn.Node_Id :=
                                                       Syn.Target_Of
                                                         (Of_Tree.all,
                                                          Given);
                                                   Edge_Is_Valid : constant
                                                     Boolean :=
                                                       Is_Module_Array_Field
                                                         (Of_Tree.all, Given,
                                                          Shape.Length,
                                                          Shape.Element);
                                                begin
                                                   if Edge_Is_Valid then
                                                      Reaches_Image :=
                                                        Validate_Module_Image
                                                          (Res.Bound_To
                                                             (Meanings.all,
                                                              Of_Tree.all,
                                                              Source))
                                                        and then
                                                          Reaches_Image;
                                                   else
                                                      Reaches_Image := False;
                                                   end if;
                                                end;
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end loop;
                              end;
                           else
                              Reaches_Image := False;
                           end if;
                        end;
                     end if;
                  end;
               end loop;

               Image_States (Id) :=
                 (if Reaches_Image then Valid else Invalid);
               return Reaches_Image;
            end;
         end if;

         if Syn.Kind (Of_Tree.all, Value) = Syn.Member_Selection then
            --  D70 adds the reverse static-image edge: an array datum may
            --  take one fixed-array field from a module struct.  Validation
            --  runs before the statement walk, so perform the same silent
            --  contextual admission here before following the containing
            --  declaration.  The later binding check still owns any D17
            --  disagreement.  A malformed or already refused edge is invalid
            --  silently because its contextual owner reports later.
            declare
               From : constant Syn.Node_Id :=
                 Syn.Target_Of (Of_Tree.all, Value);
               Edge_Is_Valid : constant Boolean :=
                 Landin.Checking.Type_Of (Types.all, Id) = Ty.Fixed_Array
                 and then Is_Module_Array_Field
                   (Of_Tree.all, Value,
                    Landin.Checking.Array_Length (Types.all, Id),
                    Landin.Checking.Array_Element (Types.all, Id));
               Reaches_Image : Boolean := False;
            begin
               if Edge_Is_Valid then
                  Reaches_Image :=
                    Validate_Module_Image
                      (Res.Bound_To (Meanings.all, Of_Tree.all, From));
               end if;

               Image_States (Id) :=
                 (if Reaches_Image then Valid else Invalid);
               return Reaches_Image;
            end;
         end if;

         if Syn.Kind (Of_Tree.all, Value) /= Syn.Name_Reference
           or else Res.Verdict_Of (Meanings.all, Of_Tree.all, Value)
                   /= Res.Bound
         then
            Image_States (Id) := Invalid;
            return False;
         end if;

         declare
            Source_Id : constant Res.Declaration_Id :=
              Res.Bound_To (Meanings.all, Of_Tree.all, Value);
            Reaches_Image : Boolean := False;
         begin
            if Res.Sort_Of (Meanings.all, Source_Id) = Res.Module_Binding
            then
               if Landin.Checking.Type_Of (Types.all, Id) = Ty.Fixed_Array
                 and then Landin.Checking.Type_Of (Types.all, Source_Id)
                          = Ty.Fixed_Array
                 and then Landin.Checking.Array_Length (Types.all, Source_Id)
                          = Landin.Checking.Array_Length (Types.all, Id)
                 and then Landin.Checking.Array_Element (Types.all, Source_Id)
                          = Landin.Checking.Array_Element (Types.all, Id)
               then
                  Reaches_Image := Validate_Module_Image (Source_Id);
               elsif Landin.Checking.Type_Of (Types.all, Id) = Ty.Aggregate
                 and then Landin.Checking.Type_Of (Types.all, Source_Id)
                          = Ty.Aggregate
                 and then Landin.Checking.Body_Of (Types.all, Source_Id)
                          = Landin.Checking.Body_Of (Types.all, Id)
               then
                  --  D60/D61 follow either D10/D59's absent zero image or
                  --  D66--D68's labelled folded image.  Following identities
                  --  still rejects a value chain that returns to itself.  A
                  --  body with no layout has already refused the compilation;
                  --  this graph walk adds no fallout for it.
                  Reaches_Image := Validate_Module_Image (Source_Id);
               end if;
            end if;

            Image_States (Id) :=
              (if Reaches_Image then Valid else Invalid);
            return Reaches_Image;
         end;
      end Validate_Module_Image;

      procedure Validate_Module_Images is
      begin
         for Id in Res.Declaration_Id'(1)
                   .. Res.Declaration_Id
                        (Res.Declaration_Count (Meanings.all))
         loop
            if Res.Sort_Of (Meanings.all, Id) = Res.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                       in Ty.Fixed_Array | Ty.Aggregate
            then
               declare
                  Reaches_Image : constant Boolean :=
                    Validate_Module_Image (Id);
               begin
                  pragma Unreferenced (Reaches_Image);
               end;
            end if;
         end loop;
      end Validate_Module_Images;

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
      --  chain [1940] reported, or an impossible operand [1950] will report.
      --  Overflowed is distinct: it says the mathematical answer walked past
      --  Folded and Check_Module_Fold must report it before lowering.
      procedure Fold
        (Of_Tree    : Syn.Tree;
         Node       : Syn.Node_Id;
         Depth      : Natural;
         Value      : out Ty.Folded;
         Known      : out Boolean;
         Overflowed : out Boolean);

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
        (Of_Tree    : Syn.Tree;
         Node       : Syn.Node_Id;
         Depth      : Natural;
         Value      : out Ty.Folded;
         Known      : out Boolean;
         Overflowed : out Boolean)
      is
         --  Guarded rather than caught, which is the rule
         --  Landin.Types.Evaluate already keeps: a sum too wide is
         --  entirely in the bytes being looked at.  Overflow is a
         --  distinct outcome from "undecided": an impossible operand
         --  arrives with Known=False and Overflowed=False for [1950], while
         --  an Add whose sum walks past Folded arrives with Known=False and
         --  Overflowed=True.
         --  The two demand different diagnostics at Check_Module_Fold.
         --
         --  [0300]'s wrapping arithmetic answers at the target type's
         --  own width: `u8 = 255 +% 1` is 0, and every other unsigned or
         --  signed size wraps the same way.  So the checker asks the
         --  node its result type and applies pattern arithmetic exactly
         --  as the lowering and the backend's folder do -- one semantic
         --  source for the answer bytes, three fold walks that see it.
         type Pattern is mod 2 ** 64;

         function Mask
           (V : Pattern; Bits : Landin.Targets.Bit_Width) return Pattern
           is (if Bits >= 64 then V
               else V and (2 ** Natural (Bits) - 1));

         function Is_Neg_Pattern
           (V : Pattern; Bits : Landin.Targets.Bit_Width) return Boolean
           is ((V and 2 ** (Natural (Bits) - 1)) /= 0);

         function To_Pattern
           (V : Ty.Folded; Bits : Landin.Targets.Bit_Width) return Pattern
           is (if V < 0
               then Mask (0 - Pattern (-V), Bits)
               else Mask (Pattern (V), Bits));

         function As_Number
           (V : Pattern; Bits : Landin.Targets.Bit_Width;
            Signed : Boolean) return Ty.Folded
           is (if Signed and then Is_Neg_Pattern (V, Bits)
               then -Ty.Folded (Mask (0 - V, Bits))
               else Ty.Folded (V));

         function Fold_Width
           (Kind : Ty.Scalar_Name) return Landin.Targets.Bit_Width
           is (if Kind in Ty.Integer_Name
               then Ty.Width (Ty.Integer_Name (Kind), Facts)
               else 8);

         function Is_Signed_Type (Kind : Ty.Scalar_Name) return Boolean
           is (Kind in Ty.Integer_Name
               and then Ty.Is_Signed (Ty.Integer_Name (Kind)));

         --  The wrapping form of an [1820] operator turned into an
         --  answer at the argument's own width.  Wrapping never
         --  overflows Ty.Folded because the mask bounds every pattern
         --  before it is read back.
         procedure Wrap_Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Bits        : Landin.Targets.Bit_Width;
            Signed      : Boolean;
            Answer      : out Ty.Folded);

         procedure Wrap_Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Bits        : Landin.Targets.Bit_Width;
            Signed      : Boolean;
            Answer      : out Ty.Folded)
         is
            L : constant Pattern := To_Pattern (Left, Bits);
            R : constant Pattern := To_Pattern (Right, Bits);
         begin
            case Of_Kind is
               when Syn.Wrapping_Add =>
                  Answer := As_Number (Mask (L + R, Bits), Bits, Signed);
               when Syn.Wrapping_Subtract =>
                  Answer := As_Number (Mask (L - R, Bits), Bits, Signed);
               when Syn.Wrapping_Multiply =>
                  Answer := As_Number (Mask (L * R, Bits), Bits, Signed);
               when others =>
                  raise Landin.Compiler_Defect with
                    "Wrap_Combine reached with a non-wrapping opcode";
            end case;
         end Wrap_Combine;

         procedure Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Answer      : out Ty.Folded;
            Fits        : out Boolean;
            Overflows   : out Boolean);

         procedure Combine
           (Left, Right : Ty.Folded;
            Of_Kind     : Syn.Node_Kind;
            Answer      : out Ty.Folded;
            Fits        : out Boolean;
            Overflows   : out Boolean) is
         begin
            Answer     := 0;
            Fits       := True;
            Overflows  := False;

            case Of_Kind is
               when Syn.Add =>
                  Fits := (if Right > 0
                           then Left <= Ty.Folded'Last - Right
                           else Left >= Ty.Folded'First - Right);
                  Overflows := not Fits;

               when Syn.Subtract =>
                  Fits := (if Right > 0
                           then Left >= Ty.Folded'First + Right
                           else Left <= Ty.Folded'Last + Right);
                  Overflows := not Fits;

               when Syn.Multiply =>
                  Fits := Left = 0
                          or else abs Right
                                  <= Ty.Folded'Last / abs Left;
                  Overflows := not Fits;

               when Syn.Divide | Syn.Remainder =>
                  --  Declining rather than dividing, because there is
                  --  nothing to divide by.  Check_Operands is what turns
                  --  this into a diagnostic: [1950] refuses a divisor the
                  --  compiler knows is zero, and at module level [1940]'s
                  --  whole fold is what knowing means.  Before that rule
                  --  existed the decline was silent, and `d: u32 = 7 / 0`
                  --  was accepted.  Divide-by-zero is not overflow --
                  --  [1950] owns it -- so Overflows stays False.
                  Fits := Right /= 0;

               when others =>
                  Fits := True;
            end case;

            if not Fits then
               return;
            end if;

            case Of_Kind is
               when Syn.Add =>
                  Answer := Left + Right;

               when Syn.Subtract =>
                  Answer := Left - Right;

               when Syn.Multiply =>
                  Answer := Left * Right;

               when Syn.Divide =>
                  Answer := Left / Right;

               when Syn.Remainder =>
                  Answer := Left rem Right;

               when others =>
                  --  Width-dependent operators are handled by their own
                  --  target-aware branch below rather than by this arithmetic
                  --  helper.
                  Fits := False;
            end case;
         end Combine;
      begin
         Value      := 0;
         Known      := False;
         Overflowed := False;

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
                  Held        : Ty.Magnitude;
                  Overflow    : Boolean;
               begin
                  Ty.Evaluate
                    (Text, Syn.Base (Of_Tree, Node), Held, Overflow);

                  if not Overflow then
                     Value := Ty.Folded (Held);
                     Known := True;
                  else
                     Overflowed := True;
                  end if;
               end;

            when Syn.True_Literal =>
               Value := 1;
               Known := True;

            when Syn.False_Literal =>
               Value := 0;
               Known := True;

            when Syn.Negation =>
               declare
                  Under : Ty.Folded;
                  Under_Overflowed : Boolean;
               begin
                  Fold (Of_Tree, Syn.Operand_Of (Of_Tree, Node),
                        Depth + 1, Under, Known, Under_Overflowed);
                  Overflowed := Under_Overflowed;

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
                           Their_Value : constant Syn.Node_Id :=
                             Syn.Value_Of (Their_Tree.all, Theirs);
                        begin
                           --  D10 gives an omitted module scalar its zero
                           --  image.  It is as compile-time-known here as it
                           --  is in lowering and in the backend.
                           if Their_Value = Syn.No_Node then
                              Value := 0;
                              Known := True;
                              return;
                           end if;

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
                             (Their_Tree.all, Their_Value, Depth + 1,
                              Value, Known, Overflowed);
                           Folding (Means) := False;
                        end;
                     end if;
                  end;
               end if;

            when Syn.Add | Syn.Subtract | Syn.Multiply | Syn.Divide
               | Syn.Remainder | Syn.Wrapping_Add | Syn.Wrapping_Subtract
               | Syn.Wrapping_Multiply =>
               declare
                  Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known : Boolean;
                  Left_Overflowed, Right_Overflowed : Boolean;
                  Fits, Overflows : Boolean;
                  Result_Type : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Node);
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known, Left_Overflowed);
                  Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                        Right, Right_Known, Right_Overflowed);

                  --  An overflow in either operand still counts as an
                  --  overflow of the enclosing fold: the answer cannot be
                  --  produced without walking through the overflowing
                  --  subtree.  Report once at the outermost place a
                  --  caller decides to speak, which is Check_Module_Fold.
                  if Left_Overflowed or else Right_Overflowed then
                     Overflowed := True;
                  elsif Left_Known and then Right_Known then
                     if Op in Syn.Wrapping_Add | Syn.Wrapping_Subtract
                                | Syn.Wrapping_Multiply
                       and then Result_Type in Ty.Integer_Name
                     then
                        --  [0300]: wrapping arithmetic answers at the
                        --  operand type's own width, so 255 +% 1 on u8
                        --  is 0 and every unsigned or signed size wraps
                        --  the same way.  The pattern helpers keep the
                        --  answer inside the type's range.
                        Wrap_Combine
                          (Left, Right, Op,
                           Ty.Width
                             (Ty.Integer_Name (Result_Type), Facts),
                           Ty.Is_Signed (Ty.Integer_Name (Result_Type)),
                           Value);
                        Known := True;
                     else
                        Combine (Left, Right, Op, Value, Fits, Overflows);
                        Known := Fits;
                        Overflowed := Overflows;
                     end if;
                  end if;
               end;

            when Syn.Bitwise_And | Syn.Bitwise_Xor | Syn.Bitwise_Or
               | Syn.Shift_Left | Syn.Shift_Right =>
               declare
                  Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known : Boolean;
                  Left_Overflowed, Right_Overflowed : Boolean;
                  Kind : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Node);
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known, Left_Overflowed);
                  Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                        Right, Right_Known, Right_Overflowed);

                  if Left_Overflowed or else Right_Overflowed then
                     Overflowed := True;
                  elsif Left_Known and then Right_Known
                    and then Right >= 0
                    and then Kind in Ty.Scalar_Name
                  then
                     declare
                        Bits : constant Landin.Targets.Bit_Width :=
                          Fold_Width (Ty.Scalar_Name (Kind));
                        Signed : constant Boolean :=
                          Is_Signed_Type (Ty.Scalar_Name (Kind));
                        LP : constant Pattern := To_Pattern (Left, Bits);
                        RP : constant Pattern := To_Pattern (Right, Bits);
                        Answer : Pattern := 0;
                        Exhausted : constant Boolean :=
                          Op in Syn.Shift_Left | Syn.Shift_Right
                            and then Right >= Ty.Folded (Bits);
                     begin
                        case Op is
                           when Syn.Bitwise_And =>
                              Answer := Mask (LP and RP, Bits);
                           when Syn.Bitwise_Xor =>
                              Answer := Mask (LP xor RP, Bits);
                           when Syn.Bitwise_Or =>
                              Answer := Mask (LP or RP, Bits);
                           when Syn.Shift_Left =>
                              Answer :=
                                (if Exhausted then 0
                                 else Mask
                                        (LP * 2 ** Natural (Right), Bits));
                           when Syn.Shift_Right =>
                              Answer :=
                                (if Exhausted then 0
                                 elsif Signed and then Left < 0
                                 then Mask
                                        (not
                                           (Mask (not LP, Bits)
                                            / 2 ** Natural (Right)),
                                         Bits)
                                 else Mask
                                        (LP / 2 ** Natural (Right), Bits));
                           when others =>
                              raise Landin.Compiler_Defect with
                                "unreachable width-op fold";
                        end case;
                        Value := As_Number (Answer, Bits, Signed);
                        Known := True;
                     end;
                  end if;
               end;

            when Syn.Complement =>
               declare
                  Under : Ty.Folded;
                  Under_Known, Under_Overflowed : Boolean;
                  Kind : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Node);
               begin
                  Fold (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Depth + 1,
                        Under, Under_Known, Under_Overflowed);
                  if Under_Overflowed then
                     Overflowed := True;
                  elsif Under_Known and then Kind in Ty.Scalar_Name then
                     declare
                        Bits : constant Landin.Targets.Bit_Width :=
                          Fold_Width (Ty.Scalar_Name (Kind));
                        Signed : constant Boolean :=
                          Is_Signed_Type (Ty.Scalar_Name (Kind));
                     begin
                        Value :=
                          As_Number
                            (Mask (not To_Pattern (Under, Bits), Bits),
                             Bits, Signed);
                        Known := True;
                     end;
                  end if;
               end;

            when Syn.Logical_Not =>
               declare
                  Under : Ty.Folded;
                  Under_Known, Under_Overflowed : Boolean;
               begin
                  Fold (Of_Tree, Syn.Operand_Of (Of_Tree, Node), Depth + 1,
                        Under, Under_Known, Under_Overflowed);
                  Overflowed := Under_Overflowed;
                  if Under_Known then
                     Value := 1 - Under;
                     Known := True;
                  end if;
               end;

            when Syn.Logical_And | Syn.Logical_Or =>
               declare
                  Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known : Boolean;
                  Left_Overflowed, Right_Overflowed : Boolean;
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known, Left_Overflowed);
                  if Left_Overflowed then
                     Overflowed := True;
                  elsif Left_Known
                    and then ((Op = Syn.Logical_And and then Left = 0)
                              or else
                                (Op = Syn.Logical_Or and then Left = 1))
                  then
                     Value := Left;
                     Known := True;
                  elsif Left_Known then
                     Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                           Right, Right_Known, Right_Overflowed);
                     Overflowed := Right_Overflowed;
                     if Right_Known then
                        Value := Right;
                        Known := True;
                     end if;
                  end if;
               end;

            when Syn.Equal_To | Syn.Not_Equal_To
               | Syn.Less_Than | Syn.Less_Or_Equal
               | Syn.Greater_Than | Syn.Greater_Or_Equal =>
               declare
                  Op : constant Syn.Node_Kind := Syn.Kind (Of_Tree, Node);
                  Left, Right : Ty.Folded;
                  Left_Known, Right_Known : Boolean;
                  Left_Overflowed, Right_Overflowed : Boolean;
               begin
                  Fold (Of_Tree, Syn.Left_Of (Of_Tree, Node), Depth + 1,
                        Left, Left_Known, Left_Overflowed);
                  Fold (Of_Tree, Syn.Right_Of (Of_Tree, Node), Depth + 1,
                        Right, Right_Known, Right_Overflowed);
                  if Left_Overflowed or else Right_Overflowed then
                     Overflowed := True;
                  elsif Left_Known and then Right_Known then
                     Value :=
                       (case Op is
                           when Syn.Equal_To =>
                             (if Left = Right then 1 else 0),
                           when Syn.Not_Equal_To =>
                             (if Left /= Right then 1 else 0),
                           when Syn.Less_Than =>
                             (if Left < Right then 1 else 0),
                           when Syn.Less_Or_Equal =>
                             (if Left <= Right then 1 else 0),
                           when Syn.Greater_Than =>
                             (if Left > Right then 1 else 0),
                           when others =>
                             (if Left >= Right then 1 else 0));
                     Known := True;
                  end if;
               end;

            when Syn.Size_Of | Syn.Align_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Measured_Type (Of_Tree, Node);
                  Held : constant Ty.Type_Kind :=
                    Landin.Checking.Type_Of (Types.all, Of_Tree, Asked);
               begin
                  if Held in Ty.Scalar_Name then
                     declare
                        Size : constant Landin.Targets.Scalar_Size :=
                          Ty.Storage_Size (Ty.Scalar_Name (Held), Facts);
                     begin
                        Value :=
                          (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                           then Ty.Folded (Landin.Targets.Bytes (Size))
                           else Ty.Folded
                                  (Landin.Targets.Alignment_Of
                                     (Facts, Size)));
                        Known := True;
                     end;
                  elsif Held = Ty.Fixed_Array then
                     declare
                        Length : constant Landin.Checking.Element_Count :=
                          Landin.Checking.Array_Length
                            (Types.all, Of_Tree, Asked);
                        Element : constant Ty.Scalar_Name :=
                          Landin.Checking.Array_Element
                            (Types.all, Of_Tree, Asked);
                        Size : constant Landin.Targets.Scalar_Size :=
                          Ty.Storage_Size (Element, Facts);
                     begin
                        Value :=
                          (if Syn.Kind (Of_Tree, Node) = Syn.Align_Of
                           then (if Length = 0 then 1
                                 else Ty.Folded
                                        (Landin.Targets.Alignment_Of
                                           (Facts, Size)))
                           else Ty.Folded
                                  (Landin.Targets.Byte_Count (Length)
                                   * Landin.Targets.Byte_Count
                                       (Landin.Targets.Bytes (Size))));
                        Known := True;
                     end;
                  elsif Held = Ty.Aggregate then
                     declare
                        Declared : constant Res.Declaration_Id :=
                          Landin.Checking.Body_Of
                            (Types.all, Of_Tree, Asked);
                     begin
                        if Declared /= Res.No_Declaration
                          and then Landin.Checking.Has_Layout
                            (Types.all, Declared)
                        then
                           Value :=
                             Ty.Folded
                               (if Syn.Kind (Of_Tree, Node) = Syn.Size_Of
                                then Landin.Checking.Layout_Size
                                       (Types.all, Declared)
                                else Landin.Checking.Layout_Alignment
                                       (Types.all, Declared));
                           Known := True;
                        end if;
                     end;
                  end if;
               end;

            when Syn.Len_Of =>
               declare
                  Asked : constant Syn.Node_Id :=
                    Syn.Operand_Of (Of_Tree, Node);
               begin
                  if Syn.Kind (Of_Tree, Asked) = Syn.Array_Literal then
                     Value := Ty.Folded (Syn.Element_Count (Of_Tree, Asked));
                     Known := True;
                  elsif Syn.Kind (Of_Tree, Asked) = Syn.Name_Reference
                    and then Res.Verdict_Of (Meanings.all, Of_Tree, Asked)
                             = Res.Bound
                  then
                     declare
                        Named : constant Res.Declaration_Id :=
                          Res.Bound_To (Meanings.all, Of_Tree, Asked);
                     begin
                        if Landin.Checking.Type_Of (Types.all, Named)
                             = Ty.Fixed_Array
                        then
                           Value :=
                             Ty.Folded
                               (Landin.Checking.Array_Length
                                  (Types.all, Named));
                           Known := True;
                        end if;
                     end;
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
         Value      : constant Syn.Node_Id := Syn.Value_Of (Of_Tree, Node);
         Wanted     : Ty.Type_Kind;
         Held       : Ty.Folded;
         Known      : Boolean;
         Overflowed : Boolean;

         procedure Check_Image_Scalar
           (Each : Syn.Node_Id; Element : Ty.Scalar_Name);

         procedure Check_Image_Scalar
           (Each : Syn.Node_Id; Element : Ty.Scalar_Name)
         is
            Element_Held      : Ty.Folded;
            Element_Known     : Boolean;
            Element_Overflowed : Boolean;
         begin
            --  A literal on its own was already checked by Require's
            --  Commit_To; skip it to keep the report from doubling.  A subtree
            --  the checker already refused likewise carries its own report.
            if not
                 (Syn.Kind (Of_Tree, Each) = Syn.Integer_Literal
                  or else
                    (Syn.Kind (Of_Tree, Each) = Syn.Negation
                     and then Syn.Kind
                       (Of_Tree, Syn.Operand_Of (Of_Tree, Each))
                         = Syn.Integer_Literal))
              and then Landin.Checking.Type_Of
                         (Types.all, Of_Tree, Each) /= Ty.Ill_Typed
            then
               Fold (Of_Tree, Each, 0, Element_Held,
                     Element_Known, Element_Overflowed);

               if Element_Overflowed then
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Each),
                     Message => "this image value's fold overflows the widest"
                                & " value the compiler holds",
                     Note    => "[1940]: a module value has no moment in"
                                & " which to trap, so a fold whose result"
                                & " walks past the compiler's widest kernel"
                                & " value is refused",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Each);
               elsif Element_Known
                 and then not Ty.Holds (Element_Held, Element, Facts)
               then
                  Bad.Report
                    (Item    => Bad.Literal_Out_Of_Range,
                     Source  => Syn.Source_Of (Of_Tree),
                     Where   => Syn.Where (Of_Tree, Each),
                     Message => "this image value works out to "
                                & Written (Element_Held) & ", and no "
                                & Shown (Element) & " holds it",
                     Note    => "D24/D34/D35/D66: every module image value"
                                & " has to fit its contextual scalar type",
                     Into    => Found);
                  Landin.Checking.Refuse (Types.all, Of_Tree, Each);
               end if;
            end if;
         end Check_Image_Scalar;
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

         --  D24/D26 fold every module array literal element.  D34/D35 fold
         --  one repetition pattern; D38 folds every finite prefix expression
         --  and its one suffix pattern through the same target-aware boundary.
         --  The contextual shape checks have already run.
         if Wanted = Ty.Fixed_Array
           and then Syn.Kind (Of_Tree, Value)
                    in Syn.Array_Literal | Syn.Array_Repetition
                       | Syn.Mixed_Array_Repetition
         then
            declare
               Element : constant Ty.Scalar_Name :=
                 Landin.Checking.Array_Element
                   (Types.all, Of_Tree, Value);
            begin
               if Element in Ty.Integer_Name then
                  if Syn.Kind (Of_Tree, Value) = Syn.Array_Repetition then
                     Check_Image_Scalar
                       (Syn.Repeated_Element (Of_Tree, Value), Element);
                  else
                     for Position in
                       1 .. Syn.Element_Count (Of_Tree, Value)
                     loop
                        Check_Image_Scalar
                          (Syn.Nth_Element (Of_Tree, Value, Position),
                           Element);
                     end loop;
                     if Syn.Kind (Of_Tree, Value)
                          = Syn.Mixed_Array_Repetition
                     then
                        Check_Image_Scalar
                          (Syn.Repeated_Element (Of_Tree, Value), Element);
                     end if;
                  end if;
               end if;
            end;
            return;
         end if;

         --  D66 folds each written scalar field independently in the
         --  labelled literal's nominal context.  D67 applies the same D24
         --  fold and range owner to every finite array-field element.  Labels
         --  map to layout order through Note_Field/Field_Index.
         if Wanted = Ty.Aggregate
           and then Syn.Kind (Of_Tree, Value) = Syn.Struct_Literal
           and then Landin.Checking.Type_Of (Types.all, Of_Tree, Value)
                    = Ty.Aggregate
         then
            declare
               Wrote : constant Res.Declaration_Id :=
                 Landin.Checking.Body_Of (Types.all, Of_Tree, Value);
            begin
               for Position in
                 1 .. Syn.Field_Value_Count (Of_Tree, Value)
               loop
                  declare
                     Field : constant Syn.Node_Id :=
                       Syn.Nth_Field_Value (Of_Tree, Value, Position);
                     Which : constant Positive :=
                       Landin.Checking.Field_Index
                         (Types.all, Of_Tree, Field);
                     Image_Value : constant Syn.Node_Id :=
                       Syn.Value_Of (Of_Tree, Field);
                  begin
                     case Landin.Checking.Field_Kind_Of
                       (Types.all, Wrote, Which)
                     is
                        when Landin.Checking.Scalar_Field =>
                           declare
                              Element : constant Ty.Scalar_Name :=
                                Landin.Checking.Field_Type
                                  (Types.all, Wrote, Which);
                           begin
                              if Element in Ty.Integer_Name then
                                 Check_Image_Scalar (Image_Value, Element);
                              end if;
                           end;

                        when Landin.Checking.Fixed_Array_Field =>
                           if Syn.Kind (Of_Tree, Image_Value)
                                in Syn.Array_Literal
                                   | Syn.Array_Repetition
                                   | Syn.Mixed_Array_Repetition
                           then
                              declare
                                 Element : constant Ty.Scalar_Name :=
                                   Landin.Checking.Field_Array_Element
                                     (Types.all, Wrote, Which);
                              begin
                                 if Element in Ty.Integer_Name then
                                    if Syn.Kind (Of_Tree, Image_Value)
                                         = Syn.Array_Repetition
                                    then
                                       Check_Image_Scalar
                                         (Syn.Repeated_Element
                                            (Of_Tree, Image_Value),
                                          Element);
                                    else
                                       for Each in
                                         1 .. Syn.Element_Count
                                                (Of_Tree, Image_Value)
                                       loop
                                          Check_Image_Scalar
                                            (Syn.Nth_Element
                                               (Of_Tree, Image_Value, Each),
                                             Element);
                                       end loop;

                                       if Syn.Kind (Of_Tree, Image_Value)
                                            = Syn.Mixed_Array_Repetition
                                       then
                                          Check_Image_Scalar
                                            (Syn.Repeated_Element
                                               (Of_Tree, Image_Value),
                                             Element);
                                       end if;
                                    end if;
                                 end if;
                              end;
                           end if;

                        when Landin.Checking.Aggregate_Field =>
                           raise Landin.Compiler_Defect with
                             "a nested aggregate image reached checking";

                        when Landin.Checking.Variant_Field =>
                           declare
                              Selected : constant Positive :=
                                Positive
                                  (Landin.Checking.Field_Index
                                     (Types.all, Of_Tree, Image_Value));
                           begin
                              if Syn.Kind (Of_Tree, Image_Value)
                                   = Syn.Struct_Literal
                              then
                                 for Each in
                                   1 .. Syn.Field_Value_Count
                                          (Of_Tree, Image_Value)
                                 loop
                                    declare
                                       Label : constant Syn.Node_Id :=
                                         Syn.Nth_Field_Value
                                           (Of_Tree, Image_Value, Each);
                                       Payload : constant Positive :=
                                         Positive
                                           (Landin.Checking.Field_Index
                                              (Types.all, Of_Tree, Label));
                                       Shape : constant
                                         Landin.Checking.Field_Shape :=
                                           Landin.Checking
                                             .Nth_Variant_Case_Field
                                               (Types.all, Wrote, Which,
                                                Selected, Payload);
                                    begin
                                       if Shape.Kind =
                                            Landin.Checking.Scalar_Field
                                         and then Shape.Element
                                           in Ty.Integer_Name
                                       then
                                          Check_Image_Scalar
                                            (Syn.Value_Of (Of_Tree, Label),
                                             Shape.Element);
                                       elsif Shape.Kind =
                                         Landin.Checking.Fixed_Array_Field
                                         and then Shape.Element
                                           in Ty.Integer_Name
                                       then
                                          declare
                                             Given : constant Syn.Node_Id :=
                                               Syn.Value_Of
                                                 (Of_Tree, Label);
                                          begin
                                             if Syn.Kind (Of_Tree, Given)
                                                  = Syn.Array_Repetition
                                             then
                                                Check_Image_Scalar
                                                  (Syn.Repeated_Element
                                                     (Of_Tree, Given),
                                                   Shape.Element);
                                             elsif Syn.Kind (Of_Tree, Given)
                                               in Syn.Array_Literal
                                                  | Syn
                                                    .Mixed_Array_Repetition
                                             then
                                                for Position in
                                                  1 .. Syn.Element_Count
                                                         (Of_Tree, Given)
                                                loop
                                                   Check_Image_Scalar
                                                     (Syn.Nth_Element
                                                        (Of_Tree, Given,
                                                         Position),
                                                      Shape.Element);
                                                end loop;

                                                if Syn.Kind (Of_Tree, Given)
                                                     = Syn
                                                       .Mixed_Array_Repetition
                                                then
                                                   Check_Image_Scalar
                                                     (Syn.Repeated_Element
                                                        (Of_Tree, Given),
                                                      Shape.Element);
                                                end if;
                                             end if;
                                          end;
                                       end if;
                                    end;
                                 end loop;
                              end if;
                           end;
                     end case;
                  end;
               end loop;
            end;
            return;
         end if;

         if Wanted not in Ty.Integer_Name then
            return;
         end if;

         Fold (Of_Tree, Value, 0, Held, Known, Overflowed);

         --  A literal on its own is already checked where its context gave
         --  it a type, so this only speaks about a fold the checker has
         --  not otherwise seen.
         if Syn.Kind (Of_Tree, Value) = Syn.Integer_Literal
           or else
             (Syn.Kind (Of_Tree, Value) = Syn.Negation
              and then Syn.Kind
                (Of_Tree, Syn.Operand_Of (Of_Tree, Value))
                  = Syn.Integer_Literal)
         then
            return;
         end if;

         if Overflowed then
            Bad.Report
              (Item    => Bad.Literal_Out_Of_Range,
               Source  => Syn.Source_Of (Of_Tree),
               Where   => Syn.Where (Of_Tree, Value),
               Message => "this fold overflows the widest value the"
                          & " compiler holds",
               Note    => "[1940]: a module value has no moment in which"
                          & " to trap, so a fold whose result walks past"
                          & " the compiler's widest kernel value is refused",
               Into    => Found);
            Landin.Checking.Refuse (Types.all, Of_Tree, Value);
         elsif Known and then not Ty.Holds (Held, Wanted, Facts) then
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
               declare
                  Ignored_Overflow : Boolean;
               begin
                  Fold (Of_Tree, Right, 0, Amount, Known, Ignored_Overflow);
                  --  Check_Module_Fold has already reported an overflowing
                  --  divisor or shift amount; nothing further to say here.
                  if Ignored_Overflow then
                     Known := False;
                  end if;
               end;
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
            elsif Res.Sort_Of (Meanings.all, Id) = Res.Case_Name then
               --  D74 gives a case a declaration identity so forward uses,
               --  duplicates and module collisions have ordinary name
               --  semantics.  D75/D76 deliberately keep that identity
               --  without a general value type, so it must not enter
               --  Declared_As or Infer: both are paths for declarations that
               --  carry storage.
               Landin.Checking.Settle (Types.all, Id, Ty.Not_Typed);
            elsif Res.Sort_Of (Meanings.all, Id) = Res.Pattern_Binding then
               --  D78 settles each positional payload alias only after its
               --  arm has been paired with a case.
               null;
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
           and then Res.Sort_Of (Meanings.all, Id) /= Res.Pattern_Binding
         then
            Infer (Id);
         end if;
      end loop;

      --  Module arrays and structs have no run-before-main copy.  Their
      --  direct-name image chains therefore have to terminate at a static
      --  image rather than returning to a declaration already being visited.
      Validate_Module_Images;

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
                              Landin.Stages.Checking.Flow.Check_Function
                                (Context, Of_Tree.all, Node, Runs, Result,
                                 Found);
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
