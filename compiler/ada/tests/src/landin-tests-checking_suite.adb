--  What the checker answers about nominal aggregate identity, asked directly.
--
--  Struct values are not enabled yet, so no source expression can expose the
--  distinction from outside.  Lowering needs the answer before it can admit
--  one: this asks the table at that seam rather than pretending equal layouts
--  prove [0710]'s nominal rule.

with Landin.Checking;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Checking_Suite is

   use type Landin.Provenance.Declaration_Id;
   use type Landin.Resolution.Declaration_Sort;
   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
   use type Landin.Syntax.Node_Kind;
   use type Landin.Checking.Element_Count;
   use type Landin.Types.Type_Kind;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;

   LF : constant Character := Character'Val (10);

   Program : constant String :=
     "ahead: type = point" & LF
     & "point: type = struct" & LF
     & "    x: i32" & LF
     & "end point" & LF
     & "same: type = point" & LF
     & "again: type = same" & LF
     & "other: type = struct" & LF
     & "    x: i32" & LF
     & "end other" & LF;

   Layout_Program : constant String :=
     "ahead: type = span" & LF
     & "span: type = struct" & LF
     & "    from: i32" & LF
     & "    to: i32" & LF
     & "    tag: bool" & LF
     & "end span" & LF
     & "same: type = span" & LF
     & "machine: type = struct" & LF
     & "    word: usize" & LF
     & "    tag: bool" & LF
     & "end machine" & LF;

   procedure Declarations_Give_Structs_Their_Identity
     (Item : in out Landin.Testing.Context);

   procedure Declared_Structs_Follow_Target_Layout
     (Item : in out Landin.Testing.Context);

   procedure Declarations_Give_Structs_Their_Identity
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source (Work, "identity.ldn", Program);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the declarations are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);

         Ahead_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 1);
         Point_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 2);
         Alias_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 3);
         Again_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 4);
         Other_Node : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Nth_Declaration (Of_Tree.all, 5);

         function Declaration_At (Node : Landin.Syntax.Node_Id)
           return Landin.Provenance.Declaration_Id;

         function Declaration_At (Node : Landin.Syntax.Node_Id)
           return Landin.Provenance.Declaration_Id is
         begin
            for Id in Landin.Provenance.Declaration_Id'(1)
                      .. Landin.Provenance.Declaration_Id
                           (Landin.Resolution.Declaration_Count (Meanings.all))
            loop
               if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                 and then Landin.Resolution.Node_Of (Meanings.all, Id) = Node
               then
                  return Id;
               end if;
            end loop;

            return Landin.Provenance.No_Declaration;
         end Declaration_At;

         Ahead : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Ahead_Node);
         Point : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Point_Node);
         Alias : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Alias_Node);
         Again : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Again_Node);
         Other : constant Landin.Provenance.Declaration_Id :=
           Declaration_At (Other_Node);
         Point_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Point_Node);
         Alias_Type : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Alias_Node);
         Other_Body : constant Landin.Syntax.Node_Id :=
           Landin.Syntax.Declared_Type (Of_Tree.all, Other_Node);
      begin
         Landin.Testing.Check
           (Item,
            Ahead /= Landin.Provenance.No_Declaration
            and then Point /= Landin.Provenance.No_Declaration
            and then Alias /= Landin.Provenance.No_Declaration
            and then Again /= Landin.Provenance.No_Declaration
            and then Other /= Landin.Provenance.No_Declaration,
            "all five declarations have identities");
         Landin.Testing.Check
           (Item, Landin.Checking.Body_Of (Types.all, Point) = Point,
            "a struct body gives its declaration a fresh identity");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Body_Of
              (Types.all, Of_Tree.all, Point_Body) = Point,
            "the struct body node carries the identity it created");
         Landin.Testing.Check
           (Item, Landin.Checking.Body_Of (Types.all, Ahead) = Point,
            "a forward alias receives the later declaration's identity");
         Landin.Testing.Check
           (Item, Landin.Checking.Body_Of (Types.all, Alias) = Point,
            "an alias keeps the aggregate identity it names");
         Landin.Testing.Check
           (Item, Landin.Checking.Body_Of (Types.all, Again) = Point,
            "an alias chain keeps one aggregate identity");
         Landin.Testing.Check
           (Item, Landin.Checking.Body_Of (Types.all, Other) = Other,
            "a second struct body gives its declaration another identity");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Body_Of
              (Types.all, Of_Tree.all, Other_Body) = Other,
            "the second struct body node carries its own identity");
         Landin.Testing.Check
           (Item, Point /= Other,
            "same-shaped named structs are not one declaration");
         Landin.Testing.Check
           (Item,
            Landin.Checking.Body_Of (Types.all, Of_Tree.all, Alias_Type)
              = Point,
            "the type-reference node carries the identity into later stages");
      end;
   end Declarations_Give_Structs_Their_Identity;

   procedure Declared_Structs_Follow_Target_Layout
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target
        (Facts             : Landin.Targets.Target_Facts;
         Machine_Tag       : Natural;
         Machine_Extent    : Natural;
         Machine_Alignment : Natural;
         Machine_Size      : Natural);

      procedure Check_Target
        (Facts             : Landin.Targets.Target_Facts;
         Machine_Tag       : Natural;
         Machine_Extent    : Natural;
         Machine_Alignment : Natural;
         Machine_Size      : Natural)
      is
         Work  : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source (Work, "layout.ldn", Layout_Program);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work),
            "the scalar-only structs are accepted");

         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Src);
            Meanings : constant not null access Landin.Resolution.Table :=
              Landin.Stages.Meanings (Work);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);

            function Declaration_At (Position : Positive)
              return Landin.Provenance.Declaration_Id;

            function Declaration_At (Position : Positive)
              return Landin.Provenance.Declaration_Id
            is
               Node : constant Landin.Syntax.Node_Id :=
                 Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
            begin
               for Id in Landin.Provenance.Declaration_Id'(1)
                         .. Landin.Provenance.Declaration_Id
                              (Landin.Resolution.Declaration_Count
                                 (Meanings.all))
               loop
                  if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                    and then Landin.Resolution.Node_Of (Meanings.all, Id)
                                 = Node
                  then
                     return Id;
                  end if;
               end loop;

               return Landin.Provenance.No_Declaration;
            end Declaration_At;

            Ahead   : constant Landin.Provenance.Declaration_Id :=
              Declaration_At (1);
            Span    : constant Landin.Provenance.Declaration_Id :=
              Declaration_At (2);
            Same    : constant Landin.Provenance.Declaration_Id :=
              Declaration_At (3);
            Machine : constant Landin.Provenance.Declaration_Id :=
              Declaration_At (4);
         begin
            Landin.Testing.Check
              (Item, Landin.Checking.Has_Layout (Types.all, Span),
               "the ordinary struct has a layout");
            Landin.Testing.Check_Equal
              (Item, Landin.Checking.Layout_Field_Count (Types.all, Span), 3,
               "the layout has every field");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Span, 1)),
               0, "the first i32 starts at zero");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Span, 2)),
               4, "the second i32 follows the first");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Span, 3)),
               8, "the bool keeps source order and occupies one byte");
            Landin.Testing.Check_Equal
              (Item, Natural (Landin.Checking.Layout_Extent (Types.all, Span)),
               9, "the fields reach nine bytes");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Alignment (Types.all, Span)),
               4, "the widest field aligns the struct");
            Landin.Testing.Check_Equal
              (Item, Natural (Landin.Checking.Layout_Size (Types.all, Span)),
               12, "tail padding makes arrays stay aligned");

            declare
               type Alias_Array is array (Positive range <>) of
                 Landin.Provenance.Declaration_Id;
            begin
               for Alias of Alias_Array'[Ahead, Same] loop
                  Landin.Testing.Check
                    (Item, Landin.Checking.Has_Layout (Types.all, Alias),
                     "an aggregate alias exposes its body's layout");
                  Landin.Testing.Check_Equal
                    (Item,
                     Landin.Checking.Layout_Field_Count (Types.all, Alias),
                     3, "an alias has every field");
                  Landin.Testing.Check_Equal
                    (Item,
                     Natural
                       (Landin.Checking.Field_Offset (Types.all, Alias, 3)),
                     8, "an alias has the body's offsets");
                  Landin.Testing.Check_Equal
                    (Item,
                     Natural
                       (Landin.Checking.Layout_Extent (Types.all, Alias)),
                     9, "an alias has the body's extent");
                  Landin.Testing.Check_Equal
                    (Item,
                     Natural
                       (Landin.Checking.Layout_Alignment (Types.all, Alias)),
                     4, "an alias has the body's alignment");
                  Landin.Testing.Check_Equal
                    (Item,
                     Natural (Landin.Checking.Layout_Size (Types.all, Alias)),
                     12, "an alias has the body's size");
               end loop;
            end;

            Landin.Testing.Check
              (Item, Landin.Checking.Has_Layout (Types.all, Machine),
               "the pointer-width struct has a layout");
            Landin.Testing.Check_Equal
              (Item,
               Natural
                 (Landin.Checking.Field_Offset (Types.all, Machine, 2)),
               Machine_Tag, "usize follows the compilation target");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Extent (Types.all, Machine)),
               Machine_Extent, "its extent follows the target");
            Landin.Testing.Check_Equal
              (Item,
               Natural
                 (Landin.Checking.Layout_Alignment (Types.all, Machine)),
               Machine_Alignment, "its alignment follows the target");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Size (Types.all, Machine)),
               Machine_Size, "its size follows the target");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, 8, 9, 8, 16);
      Check_Target (Landin.Targets.Synthetic_32, 4, 5, 4, 8);
   end Declared_Structs_Follow_Target_Layout;

   --  D17: an array's identity is its length and its element, so two
   --  written the same way are one type and an alias keeps that identity.
   --  Its extent is the element repeated, which needs a target: `usize`
   --  is four elements of four bytes on a 32-bit description and of eight
   --  on Linux x86-64.
   procedure Array_Types_Are_Their_Length_And_Element
     (Item : in out Landin.Testing.Context);

   procedure Array_Types_Are_Their_Length_And_Element
     (Item : in out Landin.Testing.Context)
   is
      Source_Text : constant String :=
        "row: type = [4]u8" & LF
        & "same: type = [4]u8" & LF
        & "alias: type = row" & LF
        & "words: type = [3]u32" & LF
        & "wide: type = [4]usize" & LF;

      procedure Check_Target
        (Facts      : Landin.Targets.Target_Facts;
         Wide_Size  : Natural;
         Wide_Align : Natural);

      procedure Check_Target
        (Facts      : Landin.Targets.Target_Facts;
         Wide_Size  : Natural;
         Wide_Align : Natural)
      is
         Work  : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
      begin
         Src := Landin.Stages.Add_Source (Work, "arrays.ldn", Source_Text);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
         Landin.Testing.Check
           (Item, not Landin.Stages.Failed (Work),
            "the array declarations are accepted");

         declare
            Of_Tree : constant not null access constant Landin.Syntax.Tree :=
              Landin.Syntax.Forest.Tree_Of
                (Landin.Stages.Trees (Work).all, Src);
            Types : constant not null access Landin.Checking.Table :=
              Landin.Stages.Types (Work);

            function Written_At (Position : Positive)
              return Landin.Syntax.Node_Id
              is (Landin.Syntax.Declared_Type
                    (Of_Tree.all,
                     Landin.Syntax.Nth_Declaration (Of_Tree.all, Position)));

            Row   : constant Landin.Syntax.Node_Id := Written_At (1);
            Same  : constant Landin.Syntax.Node_Id := Written_At (2);
            Words : constant Landin.Syntax.Node_Id := Written_At (4);
            Wide  : constant Landin.Syntax.Node_Id := Written_At (5);

            Size      : Landin.Targets.Byte_Count;
            Alignment : Landin.Targets.Byte_Alignment;
         begin
            Landin.Testing.Check_Equal
              (Item,
               Natural
                 (Landin.Checking.Array_Length (Types.all, Of_Tree.all, Row)),
               4, "the length is the bound that was written");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Array_Element (Types.all, Of_Tree.all, Row)
                 = Landin.Types.U8,
               "and the element is the type that was written");

            --  D17's whole point: the same shape twice is one type.
            Landin.Testing.Check
              (Item,
               Landin.Checking.Array_Length (Types.all, Of_Tree.all, Row)
                 = Landin.Checking.Array_Length
                     (Types.all, Of_Tree.all, Same)
               and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Row)
                        = Landin.Checking.Array_Element
                            (Types.all, Of_Tree.all, Same),
               "two arrays written the same way agree");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Array_Length (Types.all, Of_Tree.all, Words)
                 /= Landin.Checking.Array_Length
                      (Types.all, Of_Tree.all, Row),
               "and two written differently do not");

            Landin.Checking.Array_Extent
              (Landin.Checking.Array_Length (Types.all, Of_Tree.all, Row),
               Landin.Checking.Array_Element (Types.all, Of_Tree.all, Row),
               Facts, Size, Alignment);
            Landin.Testing.Check_Equal
              (Item, Natural (Size), 4, "four bytes end to end");
            Landin.Testing.Check_Equal
              (Item, Natural (Alignment), 1, "aligned as one of them is");

            Landin.Checking.Array_Extent
              (Landin.Checking.Array_Length (Types.all, Of_Tree.all, Words),
               Landin.Checking.Array_Element
                 (Types.all, Of_Tree.all, Words),
               Facts, Size, Alignment);
            Landin.Testing.Check_Equal
              (Item, Natural (Size), 12, "three u32 reach twelve bytes");
            Landin.Testing.Check_Equal
              (Item, Natural (Alignment), 4, "aligned as a u32 is");

            --  The declaration carries the shape too, and so does an
            --  alias of it: a later stage asks the declaration and not
            --  the node it was written at.
            declare
               function Declared (Position : Positive)
                 return Landin.Provenance.Declaration_Id;

               function Declared (Position : Positive)
                 return Landin.Provenance.Declaration_Id
               is
                  Meanings : constant not null access
                    Landin.Resolution.Table := Landin.Stages.Meanings (Work);
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Nth_Declaration (Of_Tree.all, Position);
               begin
                  for Id in Landin.Provenance.Declaration_Id'(1)
                            .. Landin.Provenance.Declaration_Id
                                 (Landin.Resolution.Declaration_Count
                                    (Meanings.all))
                  loop
                     if Landin.Resolution.Source_Of (Meanings.all, Id) = Src
                       and then Landin.Resolution.Node_Of (Meanings.all, Id)
                                = Node
                     then
                        return Id;
                     end if;
                  end loop;

                  return Landin.Provenance.No_Declaration;
               end Declared;
            begin
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length (Types.all, Declared (1))),
                  4, "the declaration carries the length");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Element (Types.all, Declared (1))
                    = Landin.Types.U8,
                  "and the element");

               --  D15's alias, which has no shape of its own to carry.
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length (Types.all, Declared (3))),
                  4, "an alias carries the shape it names");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Element (Types.all, Declared (3))
                    = Landin.Types.U8,
                  "including its element");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length (Types.all, Declared (4))),
                  3, "and a different array keeps its own");
            end;

            --  A length of zero: no room, and a byte's alignment
            --  because there is no element to be aligned as.
            Landin.Checking.Array_Extent
              (0, Landin.Types.U32, Facts, Size, Alignment);
            Landin.Testing.Check_Equal
              (Item, Natural (Size), 0, "no elements take no room");
            Landin.Testing.Check_Equal
              (Item, Natural (Alignment), 1,
               "and align to a byte, having no element to align as");

            --  The one that follows the target rather than the host.
            Landin.Checking.Array_Extent
              (Landin.Checking.Array_Length (Types.all, Of_Tree.all, Wide),
               Landin.Checking.Array_Element (Types.all, Of_Tree.all, Wide),
               Facts, Size, Alignment);
            Landin.Testing.Check_Equal
              (Item, Natural (Size), Wide_Size,
               "a pointer-width element follows the target");
            Landin.Testing.Check_Equal
              (Item, Natural (Alignment), Wide_Align,
               "and so does its alignment");
         end;
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Linux_X86_64, 32, 8);
      Check_Target (Landin.Targets.Synthetic_32, 16, 4);
   end Array_Types_Are_Their_Length_And_Element;

   --  R2.20: inference from a direct storage name carries D17's exact shape
   --  onto module and local declarations, independent of destination
   --  mutability and whether the source is module or prior-local storage.
   procedure Inferred_Array_Bindings_Carry_Their_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Array_Bindings_Carry_Their_Source_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Count : Natural := 0;
      Src   : Landin.Source.Source_Id;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "inferred-arrays.ldn",
         "source: [3]u16" & LF
         & "mut module_copy := source" & LF
         & "f: () -> none =" & LF
         & "    mut mutable_module := source" & LF
         & "    immutable_module := source" & LF
         & "    mut mutable_local := mutable_module" & LF
         & "    immutable_local := immutable_module" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, Src /= Landin.Source.No_Source, "the source was recorded");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "all four forms are accepted");

      declare
         Meanings : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Work);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Id in Landin.Provenance.Declaration_Id'(1)
                   .. Landin.Provenance.Declaration_Id
                        (Landin.Resolution.Declaration_Count (Meanings.all))
         loop
            if Landin.Resolution.Sort_Of (Meanings.all, Id)
                 in Landin.Resolution.Local_Binding
                    | Landin.Resolution.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                       = Landin.Types.Fixed_Array
            then
               Count := Count + 1;
               Landin.Testing.Check
                 (Item, Landin.Checking.Type_Of (Types.all, Id)
                          = Landin.Types.Fixed_Array,
                  "the inferred declaration is a fixed array");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural (Landin.Checking.Array_Length (Types.all, Id)), 3,
                  "it carries the source length");
               Landin.Testing.Check
                 (Item, Landin.Checking.Array_Element (Types.all, Id)
                          = Landin.Types.U16,
                  "and the source element type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Count, 6, "module and local destinations were checked");
   end Inferred_Array_Bindings_Carry_Their_Source_Shape;

   --  D23: the written local array type gives the literal its exact shape and
   --  supplies one scalar context to every element expression.
   procedure Local_Array_Literal_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context);

   procedure Local_Array_Literal_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "literal.ldn",
         "f: () -> none =" & LF
         & "    row: [3]u16 = [1, 2 + 3, 4]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the literal is accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the literal is a fixed array");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node)),
                  3, "it carries the written length");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                  "it carries the written element type");

               for Position in
                 1 .. Landin.Syntax.Element_Count (Of_Tree.all, Node)
               loop
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Type_Of
                       (Types.all, Of_Tree.all,
                        Landin.Syntax.Nth_Element
                          (Of_Tree.all, Node, Position)) = Landin.Types.U16,
                     "each element receives the written scalar context");
               end loop;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal (Item, Seen, 1, "one literal was checked");
   end Local_Array_Literal_Takes_Its_Written_Shape;

   --  D24: the written module array type gives the literal its exact shape,
   --  its element type is the scalar context for every element expression,
   --  and forward references to other module scalar bindings are admitted
   --  because [1740] makes a module a set.
   procedure Module_Array_Literal_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context);

   procedure Module_Array_Literal_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module.ldn",
         "mut buffer: [3]u32 = [base, base + 1, 12]" & LF
         & "base: u32 = 100" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "the module literal is accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the module literal is a fixed array");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node)),
                  3, "it carries the written length");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U32,
                  "it carries the written element type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "one module literal was checked");
   end Module_Array_Literal_Takes_Its_Written_Shape;

   --  D34: a nonzero written fixed-array type supplies the complete context
   --  for either spelling, at module scope and for a local.  A written count
   --  remains an assertion that the same contextual length was named.
   procedure Typed_Repetition_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context);

   procedure Typed_Repetition_Takes_Its_Written_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "repetition.ldn",
         "seed: u64 = 0x123456789ABCDEF0" & LF
         & "counted: [3]u64 = [3 of seed]" & LF
         & "contextual: [2]u64 = [of seed + 1]" & LF
         & "f: () -> none =" & LF
         & "    local: [4]u64 = [of seed]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local typed repetitions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the contextual repetition is a fixed array");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 3, "all three typed repetitions carry a shape");
   end Typed_Repetition_Takes_Its_Written_Shape;

   --  D36: only an explicitly typed local supplies the complete shape for a
   --  nonempty literal prefix followed by one repeated suffix expression.
   procedure Mixed_Repetition_Takes_Its_Typed_Written_Shape
     (Item : in out Landin.Testing.Context);

   procedure Mixed_Repetition_Takes_Its_Typed_Written_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "mixed-repetition.ldn",
         "module_row: [4]u16 = [1, 2 + 1, of 4]" & LF
         & "f: (first: u16, repeated: u16) -> none =" & LF
         & "    row: [4]u16 = [first, first + 1, of repeated]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "explicitly typed local and module mixed repetitions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Mixed_Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node) = 4
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                  "the mixed repetition carries the written array shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both typed mixed repetitions carry a shape");
   end Mixed_Repetition_Takes_Its_Typed_Written_Shape;

   --  D37: a mutable fixed-array assignment place supplies the complete shape
   --  for a nonempty prefix followed by one repeated suffix expression.  Both
   --  local frame storage and module storage use that same contextual rule.
   procedure Mixed_Repetition_Assignment_Takes_Its_Destination_Shape
     (Item : in out Landin.Testing.Context);

   procedure Mixed_Repetition_Assignment_Takes_Its_Destination_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "mixed-assignment.ldn",
         "mut state: [3]u16" & LF
         & "f: (first: u16, repeated: u16) -> none =" & LF
         & "    mut row: [4]u16" & LF
         & "    row = [first, first + 1, of repeated]" & LF
         & "    state = [first, of repeated]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "local and module mixed-repetition assignments are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Mixed_Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                  "the assignment gives the mixed form its element type");
               Landin.Testing.Check_Equal
                 (Item,
                  Natural
                    (Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node)),
                  (if Seen = 1 then 4 else 3),
                  "the mixed form carries its destination length");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both mixed assignments carry a shape");
   end Mixed_Repetition_Assignment_Takes_Its_Destination_Shape;

   --  D33: the written repetition count and its one scalar expression supply
   --  an inferred local's compact D17 shape.  A typed expression retains its
   --  type and an untyped integer receives [0200]'s default.
   procedure Inferred_Repetition_Carries_Its_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Repetition_Carries_Its_Source_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "repetition.ldn",
         "f: (seed: u16) -> none =" & LF
         & "    typed := [3 of seed]" & LF
         & "    defaulted := [2 of 1]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "both inferred repetitions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the repetition is recorded as a fixed array");

               if Seen = 1 then
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node) = 3
                     and then Landin.Checking.Array_Element
                       (Types.all, Of_Tree.all, Node) = Landin.Types.U16,
                     "a typed scalar supplies the three-element shape");
               else
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Array_Length
                       (Types.all, Of_Tree.all, Node) = 2
                     and then Landin.Checking.Array_Element
                       (Types.all, Of_Tree.all, Node)
                         = Landin.Types.Default_Integer,
                     "an untyped scalar supplies the default integer shape");
               end if;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both repetition nodes carry a shape");
   end Inferred_Repetition_Carries_Its_Source_Shape;

   --  D35: a counted repetition supplies the same inferred shape at module
   --  scope, where its scalar expression must also satisfy [1940].
   procedure Inferred_Module_Repetition_Carries_Its_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Module_Repetition_Carries_Its_Source_Shape
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module-repetition.ldn",
         "seed: u16 = 40" & LF
         & "typed := [3 of seed + 2]" & LF
         & "defaulted := [2 of 1]" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "both inferred module repetitions are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Array_Repetition
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array,
                  "the module repetition is recorded as a fixed array");
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node)
                      = (if Seen = 1 then 3 else 2)
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node)
                      = (if Seen = 1
                         then Landin.Types.U16
                         else Landin.Types.Default_Integer),
                  "the count and scalar supply the inferred module shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both module repetition nodes carry a shape");
   end Inferred_Module_Repetition_Carries_Its_Source_Shape;

   --  D39: an explicitly typed module scalar supplies `zeroed`'s scalar
   --  context, including when a type alias supplies the enabled scalar.
   procedure Module_Scalar_Zeroed_Takes_Its_Written_Type
     (Item : in out Landin.Testing.Context);

   procedure Module_Scalar_Zeroed_Takes_Its_Written_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module.ldn",
         "word: type = u32" & LF
         & "number: word = zeroed" & LF
         & "flag: bool = zeroed" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed module scalar zeroed initializers are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = (if Seen = 1
                       then Landin.Types.U32
                       else Landin.Types.Bool),
                  "zeroed carries the resolved written scalar type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both scalar zeroed nodes were checked");
   end Module_Scalar_Zeroed_Takes_Its_Written_Type;

   --  D40: an explicitly typed local scalar supplies `zeroed`'s scalar
   --  context, including through an alias.  Reading both bindings also pins
   --  that their initializers make them definitely assigned.
   procedure Local_Scalar_Zeroed_Takes_Its_Written_Type
     (Item : in out Landin.Testing.Context);

   procedure Local_Scalar_Zeroed_Takes_Its_Written_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "local.ldn",
         "word: type = u32" & LF
         & "f: () -> (result: u32) =" & LF
         & "    number: word = zeroed" & LF
         & "    flag: bool = zeroed" & LF
         & "    if flag then" & LF
         & "        result = 1" & LF
         & "    else" & LF
         & "        result = number" & LF
         & "    end if" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed local scalar zeroed initializers are accepted and assigned");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = (if Seen = 1
                       then Landin.Types.U32
                       else Landin.Types.Bool),
                  "local zeroed carries the resolved written scalar type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both local scalar zeroed nodes were checked");
   end Local_Scalar_Zeroed_Takes_Its_Written_Type;

   --  D41: a mutable module scalar destination supplies `zeroed`'s scalar
   --  context, including when an alias supplies that destination type.
   procedure Module_Scalar_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Module_Scalar_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "module-assignment.ldn",
         "word: type = u32" & LF
         & "mut number: word" & LF
         & "f: () -> none =" & LF
         & "    number = zeroed" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a module scalar destination gives zeroed its type");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.U32,
                  "assigned zeroed carries the resolved destination type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the assigned zeroed node was checked");
   end Module_Scalar_Assignment_Gives_Zeroed_Its_Type;

   --  D41: assignment to a mutable local scalar also supplies `zeroed`'s
   --  resolved scalar type and establishes definite assignment.
   procedure Local_Scalar_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Local_Scalar_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "local-assignment.ldn",
         "truth: type = bool" & LF
         & "f: () -> (result: bool) =" & LF
         & "    mut flag: truth" & LF
         & "    flag = zeroed" & LF
         & "    result = flag" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a local scalar destination types zeroed and becomes assigned");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Bool,
                  "assigned zeroed carries the resolved local type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the local assigned zeroed node was checked");
   end Local_Scalar_Assignment_Gives_Zeroed_Its_Type;

   --  D43: a scalar named return supplies `zeroed`'s resolved type, and the
   --  ordinary assignment establishes the return place before `return`.
   procedure Named_Return_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Named_Return_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "named-return-assignment.ldn",
         "word: type = u32" & LF
         & "f: () -> (result: word) =" & LF
         & "    result = zeroed" & LF
         & "    return" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a named return types zeroed and becomes assigned");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.U32,
                  "zeroed carries the resolved named-return type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the named-return zeroed node was checked");
   end Named_Return_Assignment_Gives_Zeroed_Its_Type;

   --  D42: an ordinary mutable struct field supplies `zeroed`'s resolved
   --  scalar type, including when an alias names the field type.
   procedure Struct_Field_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Struct_Field_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "field-assignment.ldn",
         "truth: type = bool" & LF
         & "flags: type = struct" & LF
         & "    ready: truth" & LF
         & "end flags" & LF
         & "mut state: flags" & LF
         & "f: () -> none =" & LF
         & "    state.ready = zeroed" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a mutable scalar field gives zeroed its type");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Bool,
                  "field zeroed carries the resolved alias type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the field zeroed node was checked");
   end Struct_Field_Assignment_Gives_Zeroed_Its_Type;

   --  D42: a fixed-array element supplies `zeroed`'s resolved scalar element
   --  type, including when an alias names that element type.
   procedure Array_Element_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context);

   procedure Array_Element_Assignment_Gives_Zeroed_Its_Type
     (Item : in out Landin.Testing.Context)
   is
      Work  : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Order : Landin.Stages.Pipeline;
      Ran   : Natural;
      Src   : Landin.Source.Source_Id;
      Seen  : Natural := 0;
   begin
      Src := Landin.Stages.Add_Source
        (Work, "element-assignment.ldn",
         "word: type = u32" & LF
         & "mut row: [2]word" & LF
         & "f: () -> none =" & LF
         & "    row[1] = zeroed" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a mutable fixed-array element gives zeroed its type");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
         Types : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Work);
      begin
         for Node in Landin.Syntax.Node_Id'(1)
                   .. Landin.Syntax.Last_Node (Of_Tree.all)
         loop
            if Landin.Syntax.Kind (Of_Tree.all, Node)
                 = Landin.Syntax.Zeroed_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.U32,
                  "element zeroed carries the resolved alias type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the element zeroed node was checked");
   end Array_Element_Assignment_Gives_Zeroed_Its_Type;

   --  D18: an array may occupy every byte a target's `usize` can name, and
   --  not one beyond it.  The same 2**32-byte array therefore belongs to a
   --  64-bit target and is refused by a 32-bit one; neither answer comes from
   --  the host running this test.
   procedure Array_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context);

   procedure Array_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target
        (Facts    : Landin.Targets.Target_Facts;
         Length   : String;
         Element  : String;
         Accepted : Boolean);

      procedure Check_Target
        (Facts    : Landin.Targets.Target_Facts;
         Length   : String;
         Element  : String;
         Accepted : Boolean)
      is
         Work  : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "extent.ldn",
            "huge: type = [" & Length & "]" & Element & LF);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "the array extent follows the target's usize");
      end Check_Target;
   begin
      Check_Target
        (Landin.Targets.Synthetic_32, "4294967295", "u8", True);
      Check_Target
        (Landin.Targets.Synthetic_32, "2147483648", "u16", False);
      Check_Target
        (Landin.Targets.Linux_X86_64, "2147483648", "u16", True);
   end Array_Extent_Follows_Usize;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "checking", "declarations give structs their identity",
         Declarations_Give_Structs_Their_Identity'Access);
      Landin.Testing.Register
        (Into, "checking", "array types are their length and element",
         Array_Types_Are_Their_Length_And_Element'Access);
      Landin.Testing.Register
        (Into, "checking", "inferred arrays carry their source shape",
         Inferred_Array_Bindings_Carry_Their_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "inferred repetition carries its source shape",
         Inferred_Repetition_Carries_Its_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "inferred module repetition carries its shape",
         Inferred_Module_Repetition_Carries_Its_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "typed repetition takes its written shape",
         Typed_Repetition_Takes_Its_Written_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "mixed repetition takes typed written shape",
         Mixed_Repetition_Takes_Its_Typed_Written_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "mixed assignment takes destination shape",
         Mixed_Repetition_Assignment_Takes_Its_Destination_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "a local array literal takes its written shape",
         Local_Array_Literal_Takes_Its_Written_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "a module array literal takes its written shape",
         Module_Array_Literal_Takes_Its_Written_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "typed module scalar gives zeroed its type",
         Module_Scalar_Zeroed_Takes_Its_Written_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "typed local scalar gives zeroed its type",
         Local_Scalar_Zeroed_Takes_Its_Written_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "module assignment gives zeroed its type",
         Module_Scalar_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "local assignment gives zeroed its type",
         Local_Scalar_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "named return gives zeroed its type",
         Named_Return_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "field assignment gives zeroed its type",
         Struct_Field_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "element assignment gives zeroed its type",
         Array_Element_Assignment_Gives_Zeroed_Its_Type'Access);
      Landin.Testing.Register
        (Into, "checking", "array extent follows usize",
         Array_Extent_Follows_Usize'Access);
      Landin.Testing.Register
        (Into, "checking", "declared structs follow target layout",
         Declared_Structs_Follow_Target_Layout'Access);
   end Register;

end Landin.Tests.Checking_Suite;
