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
   use type Landin.Checking.Field_Kind;
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
     & "end machine" & LF
     & "nested: type = struct" & LF
     & "    tag: u8" & LF
     & "    words: [2]usize" & LF
     & "    tail: u16" & LF
     & "end nested" & LF;

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
         Machine_Size      : Natural;
         Array_Offset      : Natural;
         Array_Tail        : Natural;
         Array_Extent      : Natural;
         Array_Alignment   : Natural;
         Array_Size        : Natural);

      procedure Check_Target
        (Facts             : Landin.Targets.Target_Facts;
         Machine_Tag       : Natural;
         Machine_Extent    : Natural;
         Machine_Alignment : Natural;
         Machine_Size      : Natural;
         Array_Offset      : Natural;
         Array_Tail        : Natural;
         Array_Extent      : Natural;
         Array_Alignment   : Natural;
         Array_Size        : Natural)
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
            Nested  : constant Landin.Provenance.Declaration_Id :=
              Declaration_At (5);
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

            Landin.Testing.Check
              (Item, Landin.Checking.Has_Layout (Types.all, Nested),
               "an array-field struct has its complete compact layout");
            Landin.Testing.Check
              (Item,
               Landin.Checking.Field_Kind_Of (Types.all, Nested, 2)
                 = Landin.Checking.Fixed_Array_Field
               and then Landin.Checking.Field_Array_Length
                          (Types.all, Nested, 2) = 2
               and then Landin.Checking.Field_Array_Element
                          (Types.all, Nested, 2) = Landin.Types.Usize,
               "the array field keeps one compact structural shape");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Nested, 2)),
               Array_Offset, "the array begins at its element alignment");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Field_Offset (Types.all, Nested, 3)),
               Array_Tail, "the following field begins after the whole array");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Extent (Types.all, Nested)),
               Array_Extent, "the array contributes its complete extent");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Alignment (Types.all, Nested)),
               Array_Alignment, "its element alignment reaches the struct");
            Landin.Testing.Check_Equal
              (Item,
               Natural (Landin.Checking.Layout_Size (Types.all, Nested)),
               Array_Size, "the complete nested layout receives tail padding");
         end;
      end Check_Target;
   begin
      Check_Target
        (Landin.Targets.Linux_X86_64, 8, 9, 8, 16,
         8, 24, 26, 8, 32);
      Check_Target
        (Landin.Targets.Synthetic_32, 4, 5, 4, 8,
         4, 12, 14, 4, 16);
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
   --  type, including when an alias names that element type.  D62 applies the
   --  same rule through a D48 array field on module and local storage.
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
         & "truth: type = bool" & LF
         & "holder: type = struct" & LF
         & "    flags: [1]truth" & LF
         & "    words: [2]word" & LF
         & "end holder" & LF
         & "mut row: [2]word" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    mut local: holder" & LF
         & "    row[1] = zeroed" & LF
         & "    state.flags[0] = zeroed" & LF
         & "    local.words[0] = zeroed" & LF
         & "    _ = local.words[0]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "direct and array-field elements give zeroed their scalar type");

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
                    = (if Seen = 2
                       then Landin.Types.Bool
                       else Landin.Types.U32),
                  "element zeroed carries the direct or field element type");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 3, "all element zeroed nodes were checked");
   end Array_Element_Assignment_Gives_Zeroed_Its_Type;

   --  D49: the selected fixed-array field supplies both the contextual
   --  shape of `zeroed` and the whole-field assignment fact used by the
   --  computed read that follows it.
   procedure Array_Field_Assignment_Gives_Zeroed_Its_Shape
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Assignment_Gives_Zeroed_Its_Shape
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
        (Work, "array-field-zeroed.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "f: (at: usize) -> (result: word) =" & LF
         & "    mut local: holder" & LF
         & "    local.row = zeroed" & LF
         & "    result = local.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "a local array field gives zeroed its shape and becomes complete");

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
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node) = 2
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U32,
                  "field zeroed carries the resolved fixed-array shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 1, "the array-field zeroed node was checked");
   end Array_Field_Assignment_Gives_Zeroed_Its_Shape;

   --  D52 gives D29's literal the selected field's complete contextual
   --  shape.  The selection retains its declaration-order field identity;
   --  neither fact is a target byte offset.
   procedure Array_Field_Literals_Carry_Their_Destination_Shape
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Literals_Carry_Their_Destination_Shape
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
        (Work, "array-field-literals.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "mut state: holder" & LF
         & "f: (at: usize) -> (result: word) =" & LF
         & "    state.row = [20, 22]" & LF
         & "    mut local: holder" & LF
         & "    local.row = [30, 12]" & LF
         & "    result = state.row[at] + local.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local array fields accept contextual literals");

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
                 = Landin.Syntax.Assignment
            then
               declare
                  Target : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Target_Of (Of_Tree.all, Node);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Landin.Syntax.Kind (Of_Tree.all, Target)
                       = Landin.Syntax.Member_Selection
                    and then Landin.Syntax.Kind (Of_Tree.all, Value)
                               = Landin.Syntax.Array_Literal
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Target)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Target) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Target) = Landin.Types.U32
                        and then Landin.Checking.Field_Index
                          (Types.all, Of_Tree.all, Target) = 2,
                        "the selected destination carries field two's shape");
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Value) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Value) = Landin.Types.U32,
                        "the literal receives the selected field's shape");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both contextual field literals were checked");
   end Array_Field_Literals_Carry_Their_Destination_Shape;

   --  D53 gives D32's full repetition and D37's mixed repetition the
   --  selected field's complete context.  The field identity stays a
   --  declaration-order position rather than becoming a target offset.
   procedure Array_Field_Repetitions_Carry_Their_Destination_Shape
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Repetitions_Carry_Their_Destination_Shape
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
        (Work, "array-field-repetitions.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [4]word" & LF
         & "end holder" & LF
         & "mut state: holder" & LF
         & "f: (at: usize) -> (result: word) =" & LF
         & "    state.row = [4 of 10]" & LF
         & "    state.row = [11, 12, of 13]" & LF
         & "    mut local: holder" & LF
         & "    local.row = [of 20]" & LF
         & "    local.row = [21, 22, of 23]" & LF
         & "    result = state.row[at] + local.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local array fields accept both repetition forms");

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
                 = Landin.Syntax.Assignment
            then
               declare
                  Target : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Target_Of (Of_Tree.all, Node);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Landin.Syntax.Kind (Of_Tree.all, Target)
                       = Landin.Syntax.Member_Selection
                    and then Landin.Syntax.Kind (Of_Tree.all, Value)
                               in Landin.Syntax.Array_Repetition
                                | Landin.Syntax.Mixed_Array_Repetition
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Target)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Target) = 4
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Target) = Landin.Types.U32
                        and then Landin.Checking.Field_Index
                          (Types.all, Of_Tree.all, Target) = 2,
                        "the selected destination carries field two's shape");
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Value) = 4
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Value) = Landin.Types.U32,
                        "the repetition receives the selected field's shape");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4, "all contextual field repetitions were checked");
   end Array_Field_Repetitions_Carry_Their_Destination_Shape;

   --  D54 admits the one aggregate expression context as soon as every
   --  field has an enabled copy representation.  Nominal identity stays on
   --  both names while D16 and D48 account for scalar and array fields.
   procedure Array_Bearing_Struct_Copy_Uses_Each_Field_Fact
     (Item : in out Landin.Testing.Context);

   procedure Array_Bearing_Struct_Copy_Uses_Each_Field_Fact
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
        (Work, "array-bearing-struct-copy.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "mut left: holder" & LF
         & "mut right: same" & LF
         & "f: (at: usize) -> (result: u32) =" & LF
         & "    right = left" & LF
         & "    mut source: same" & LF
         & "    source.tag = 1" & LF
         & "    source.row[0] = 20" & LF
         & "    source.row[1] = 22" & LF
         & "    source.tail = 3" & LF
         & "    mut destination: holder" & LF
         & "    destination = source" & LF
         & "    right = destination" & LF
         & "    destination = left" & LF
         & "    destination = destination" & LF
         & "    result = destination.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "whole copies cross module and local storage after complete reads");

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
                 = Landin.Syntax.Assignment
            then
               declare
                  Target : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Target_Of (Of_Tree.all, Node);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Landin.Checking.Type_Of
                       (Types.all, Of_Tree.all, Target)
                       = Landin.Types.Aggregate
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Body_Of
                          (Types.all, Of_Tree.all, Target)
                            = Landin.Checking.Body_Of
                                (Types.all, Of_Tree.all, Value),
                        "each whole copy keeps one nominal struct identity");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 5, "every whole aggregate assignment was checked");
   end Array_Bearing_Struct_Copy_Uses_Each_Field_Fact;

   --  D58 gives a whole mutable struct place D57's contextual zero image.
   --  Both storage classes carry the destination's nominal body, and the
   --  local clear supplies every D16/D48 field fact used by the later read.
   procedure Struct_Assignment_Gives_Zeroed_Its_Body
     (Item : in out Landin.Testing.Context);

   procedure Struct_Assignment_Gives_Zeroed_Its_Body
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
        (Work, "struct-zeroed-assignment.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "mut state: same" & LF
         & "f: (at: usize) -> (result: u32) =" & LF
         & "    mut local: holder" & LF
         & "    state = zeroed" & LF
         & "    local = zeroed" & LF
         & "    result = state.row[at] + local.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and local struct places accept zeroed and become complete");

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
                 = Landin.Syntax.Assignment
              and then Landin.Syntax.Kind
                (Of_Tree.all, Landin.Syntax.Value_Of (Of_Tree.all, Node))
                  = Landin.Syntax.Zeroed_Literal
            then
               declare
                  Place : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Target_Of (Of_Tree.all, Node);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  Seen := Seen + 1;
                  Landin.Testing.Check
                    (Item,
                     Landin.Checking.Type_Of
                       (Types.all, Of_Tree.all, Value)
                         = Landin.Types.Aggregate
                     and then Landin.Checking.Body_Of
                       (Types.all, Of_Tree.all, Value)
                         = Landin.Checking.Body_Of
                           (Types.all, Of_Tree.all, Place),
                     "zeroed carries its destination's nominal struct body");
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both whole struct zeroed assignments were checked");
   end Struct_Assignment_Gives_Zeroed_Its_Body;

   --  D55 gives a directly named whole struct D54's copy context; D57 gives
   --  `zeroed` the same written nominal context.  Each value node and binding
   --  keep the one body later layout and selection use.
   procedure Local_Struct_Initializer_Keeps_Its_Nominal_Source
     (Item : in out Landin.Testing.Context);

   procedure Local_Struct_Initializer_Keeps_Its_Nominal_Source
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
        (Work, "local-struct-initializers.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "state: holder" & LF
         & "f: (at: usize) -> (result: u32) =" & LF
         & "    mut source: same" & LF
         & "    source.tag = 1" & LF
         & "    source.row = zeroed" & LF
         & "    source.tail = 2" & LF
         & "    local: holder = source" & LF
         & "    aliased: same = local" & LF
         & "    snapshot: holder = state" & LF
         & "    blank: holder = zeroed" & LF
         & "    empty: same = zeroed" & LF
         & "    result = aliased.row[at] + snapshot.row[at]"
         & " + blank.row[at] + empty.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "storage names and zeroed initialize typed locals");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
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
                 = Landin.Resolution.Local_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Landin.Types.Aggregate
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Body_Of (Types.all, Id)
                          = Landin.Checking.Body_Of
                              (Types.all, Of_Tree.all, Value),
                        "the initializer and local share one struct body");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 5,
         "five explicit local struct initializers were checked");
   end Local_Struct_Initializer_Keeps_Its_Nominal_Source;

   --  D59 gives the same written zero-image context to module bindings.
   --  Mutable, immutable and aliased spellings all carry one nominal body;
   --  lowering may then reuse D10's existing zero datum unchanged.
   procedure Module_Struct_Zeroed_Keeps_Its_Nominal_Body
     (Item : in out Landin.Testing.Context);

   procedure Module_Struct_Zeroed_Keeps_Its_Nominal_Body
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
        (Work, "module-struct-zeroed.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "state: holder = zeroed" & LF
         & "mut aliased: same = zeroed" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed module structs accept their explicit zero image");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
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
                 = Landin.Resolution.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Landin.Types.Aggregate
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Body_Of (Types.all, Id)
                          = Landin.Checking.Body_Of
                              (Types.all, Of_Tree.all, Value),
                        "the module value and datum share one struct body");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 2, "both module struct zero images were checked");
   end Module_Struct_Zeroed_Keeps_Its_Nominal_Body;

   --  D60/D61 follow a direct module-storage name across forward declarations
   --  and aliases while retaining [0710]'s one nominal body in typed and
   --  inferred destinations.  The source name remains contextual here.
   procedure Module_Struct_Image_Chains_Keep_Their_Nominal_Body
     (Item : in out Landin.Testing.Context);

   procedure Module_Struct_Image_Chains_Keep_Their_Nominal_Body
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
        (Work, "module-struct-images.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "mut first: same = later" & LF
         & "second: holder = first" & LF
         & "mut inferred := later" & LF
         & "typed_from_inferred: holder = inferred" & LF
         & "later: holder = zeroed" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module struct image chains are accepted");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
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
                 = Landin.Resolution.Module_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Landin.Types.Aggregate
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node
                    and then Landin.Syntax.Kind (Of_Tree.all, Value)
                               = Landin.Syntax.Name_Reference
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Body_Of (Types.all, Id)
                          = Landin.Checking.Body_Of
                              (Types.all, Of_Tree.all, Value),
                        "each image source has the destination's body");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4, "the four direct-name links were checked");
   end Module_Struct_Image_Chains_Keep_Their_Nominal_Body;

   --  D56 infers the same nominal body from a direct struct storage name.
   --  The inferred declaration must carry that identity before later
   --  selections, copies and lowering ask for its layout.
   procedure Inferred_Local_Struct_Keeps_Its_Nominal_Source
     (Item : in out Landin.Testing.Context);

   procedure Inferred_Local_Struct_Keeps_Its_Nominal_Source
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
        (Work, "inferred-local-struct-initializers.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]u32" & LF
         & "    tail: u16" & LF
         & "end holder" & LF
         & "same: type = holder" & LF
         & "state: holder" & LF
         & "f: (at: usize) -> (result: u32) =" & LF
         & "    mut source: same" & LF
         & "    source.tag = 1" & LF
         & "    source.row = zeroed" & LF
         & "    source.tail = 2" & LF
         & "    local := source" & LF
         & "    aliased := local" & LF
         & "    snapshot := state" & LF
         & "    mut state := state" & LF
         & "    result = aliased.row[at] + snapshot.row[at]"
         & " + state.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "module and completed local sources infer local structs");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
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
                 = Landin.Resolution.Local_Binding
              and then Landin.Checking.Type_Of (Types.all, Id)
                         = Landin.Types.Aggregate
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node
                    and then Landin.Syntax.Declared_Type
                               (Of_Tree.all, Node) = Landin.Syntax.No_Node
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Aggregate
                        and then Landin.Checking.Body_Of (Types.all, Id)
                          = Landin.Checking.Body_Of
                              (Types.all, Of_Tree.all, Value),
                        "the inferred local carries its source struct body");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4,
         "four inferred local struct initializers were checked");
   end Inferred_Local_Struct_Keeps_Its_Nominal_Source;

   --  D50: a fixed-array field may supply or receive D20's complete copy.
   --  The source read uses the field-qualified whole-array fact established
   --  by D49 or an earlier copy, rather than D16's scalar-field bit.
   procedure Array_Field_Copy_Uses_Whole_Field_Facts
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Copy_Uses_Whole_Field_Facts
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
        (Work, "array-field-copy.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "f: (at: usize) -> (result: word) =" & LF
         & "    mut left: holder" & LF
         & "    mut right: holder" & LF
         & "    mut words: [2]word" & LF
         & "    left.row = zeroed" & LF
         & "    right.row = left.row" & LF
         & "    words = right.row" & LF
         & "    right.row = words" & LF
         & "    result = right.row[at]" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "field and direct-array copy endpoints are accepted");

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
                 = Landin.Syntax.Member_Selection
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Fixed_Array
                  and then Landin.Checking.Array_Length
                    (Types.all, Of_Tree.all, Node) = 2
                  and then Landin.Checking.Array_Element
                    (Types.all, Of_Tree.all, Node) = Landin.Types.U32,
                  "each contextual field endpoint carries one array shape");
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 6, "six contextual array-field selections were checked");
   end Array_Field_Copy_Uses_Whole_Field_Facts;

   --  D51 gives a selected fixed-array field D21's initializer context for
   --  a local binding only.  Both written and inferred destinations carry
   --  the field shape without making the selection a general value.
   procedure Array_Field_Initializers_Carry_Their_Source_Shape
     (Item : in out Landin.Testing.Context);

   procedure Array_Field_Initializers_Carry_Their_Source_Shape
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
        (Work, "array-field-initializers.ldn",
         "word: type = u32" & LF
         & "holder: type = struct" & LF
         & "    row: [2]word" & LF
         & "end holder" & LF
         & "state: holder" & LF
         & "f: () -> none =" & LF
         & "    module_typed: [2]word = state.row" & LF
         & "    module_inferred := state.row" & LF
         & "    mut local: holder" & LF
         & "    local.row = zeroed" & LF
         & "    local_typed: [2]word = local.row" & LF
         & "    local_inferred := local.row" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed and inferred local bindings accept either field source");

      declare
         Of_Tree : constant not null access constant Landin.Syntax.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Work).all, Src);
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
                 = Landin.Resolution.Local_Binding
            then
               declare
                  Node : constant Landin.Syntax.Node_Id :=
                    Landin.Resolution.Node_Of (Meanings.all, Id);
                  Value : constant Landin.Syntax.Node_Id :=
                    Landin.Syntax.Value_Of (Of_Tree.all, Node);
               begin
                  if Value /= Landin.Syntax.No_Node
                    and then Landin.Syntax.Kind (Of_Tree.all, Value)
                               = Landin.Syntax.Member_Selection
                  then
                     Seen := Seen + 1;
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of (Types.all, Id)
                          = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Id) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Id) = Landin.Types.U32
                        and then Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Value)
                            = Landin.Types.Fixed_Array,
                        "the binding and contextual selection share a shape");
                  end if;
               end;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4, "four local field initializers were checked");
   end Array_Field_Initializers_Carry_Their_Source_Shape;

   --  D18: an array may occupy every byte a target's `usize` can name, and
   --  not one beyond it.  The same 2**32-byte array therefore belongs to a
   --  64-bit target and is refused by a 32-bit one; neither answer comes from
   --  the host running this test.
   procedure Array_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context);

   procedure Struct_Array_Field_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context);

   procedure Struct_Array_Field_Storage_Classes_Are_Enabled
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

   --  D45: a field that fits alone may leave no target `usize` room for
   --  the field after it.  The same declaration therefore fits the 64-bit
   --  description and is refused by the synthetic 32-bit one.
   procedure Struct_Array_Field_Extent_Follows_Usize
     (Item : in out Landin.Testing.Context)
   is
      procedure Check_Target
        (Facts    : Landin.Targets.Target_Facts;
         Accepted : Boolean);

      procedure Check_Target
        (Facts    : Landin.Targets.Target_Facts;
         Accepted : Boolean)
      is
         Work  : Landin.Stages.Compilation := Landin.Stages.Create (Facts);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source
           (Work, "struct-extent.ldn",
            "bounded: type = struct" & LF
            & "    bytes: [4294967295]u8" & LF
            & "    tail: u8" & LF
            & "end bounded" & LF
            & "answer: usize = sizeof bounded" & LF);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "the complete struct extent follows the target's usize");
      end Check_Target;
   begin
      Check_Target (Landin.Targets.Synthetic_32, False);
      Check_Target (Landin.Targets.Linux_X86_64, True);
   end Struct_Array_Field_Extent_Follows_Usize;

   --  D47 adds a target-neutral frame shape for the same laid-out type D46
   --  admitted as zeroed module state.  Both declaration-only storage
   --  classes are enabled without forming a whole aggregate value.
   procedure Struct_Array_Field_Storage_Classes_Are_Enabled
     (Item : in out Landin.Testing.Context)
   is
      Prefix : constant String :=
        "holder: type = struct" & LF
        & "    row: [2]u32" & LF
        & "    tail: u8" & LF
        & "end holder" & LF;

      procedure Check_Source (Source : String; Accepted : Boolean);

      procedure Check_Source (Source : String; Accepted : Boolean) is
         Work  : Landin.Stages.Compilation :=
           Landin.Stages.Create (Landin.Targets.Linux_X86_64);
         Order : Landin.Stages.Pipeline;
         Ran   : Natural;
         Src   : Landin.Source.Source_Id;
         pragma Unreferenced (Src);
      begin
         Src := Landin.Stages.Add_Source (Work, "storage.ldn", Source);
         Landin.Stages.Append (Order, Frontend'Access);
         Landin.Stages.Append (Order, Names'Access);
         Landin.Stages.Append (Order, Checker'Access);
         Ran := Landin.Stages.Run (Order, Work);

         Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
         Landin.Testing.Check
           (Item, Landin.Stages.Failed (Work) /= Accepted,
            "both declaration-only storage classes accept the shape");
      end Check_Source;
   begin
      Check_Source (Prefix & "mut state: holder" & LF, True);
      Check_Source
        (Prefix
         & "f: () -> none =" & LF
         & "    mut state: holder" & LF
         & "end f" & LF,
         True);
   end Struct_Array_Field_Storage_Classes_Are_Enabled;

   --  D64/D66--D68 carry one nominal body on the contextual literal, record
   --  each source label as a declaration-order field identity, and give each
   --  module array label its field's complete static shape.
   procedure Struct_Literals_Carry_Body_And_Field_Identities
     (Item : in out Landin.Testing.Context);

   procedure Struct_Literals_Carry_Body_And_Field_Identities
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
        (Work, "struct-literals.ldn",
         "holder: type = struct" & LF
         & "    tag: u8" & LF
         & "    row: [2]usize" & LF
         & "    ready: bool" & LF
         & "    tail: u16" & LF
         & "    repeated: [2]u8" & LF
         & "    mixed: [3]u16" & LF
         & "end holder" & LF
         & "image: holder = (ready: true, row: [8, 9], tail: 11,"
         & " tag: 2, repeated: [of 7], mixed: [17, of 19])" & LF
         & "mut state: holder" & LF
         & "f: () -> none =" & LF
         & "    local: holder = (ready: true, tail: 5, tag: 3,"
         & " of zeroed)" & LF
         & "    state = (tail: 7, tag: 4, ready: false, of zeroed)" & LF
         & "    contextual: holder = (row: [8, 9], ready: zeroed,"
         & " tag: 6, tail: 10, repeated: [2 of 7],"
         & " mixed: [17, of 19])" & LF
         & "end f" & LF);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Ran := Landin.Stages.Run (Order, Work);

      Landin.Testing.Check_Equal (Item, Ran, 3, "the checker ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work),
         "typed module, local and whole-assignment literals are accepted");

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
                 = Landin.Syntax.Struct_Literal
            then
               Seen := Seen + 1;
               Landin.Testing.Check
                 (Item,
                  Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node)
                    = Landin.Types.Aggregate
                  and then Landin.Checking.Body_Of
                    (Types.all, Of_Tree.all, Node)
                      /= Landin.Resolution.No_Declaration,
                  "the literal carries its contextual nominal body");
               Landin.Testing.Check_Equal
                 (Item,
                  Landin.Checking.Field_Index
                    (Types.all, Of_Tree.all,
                     Landin.Syntax.Nth_Field_Value
                       (Of_Tree.all, Node, 1)),
                  (case Seen is
                      when 1 | 2 => 3,
                      when 3 => 4,
                      when others => 2),
                  "the first written label keeps its layout identity");
               Landin.Testing.Check_Equal
                 (Item,
                  Landin.Checking.Field_Index
                    (Types.all, Of_Tree.all,
                     Landin.Syntax.Nth_Field_Value
                       (Of_Tree.all, Node, 2)),
                  (case Seen is
                      when 1 => 2,
                      when 2 => 4,
                      when 3 => 1,
                      when others => 3),
                  "the second written label keeps its layout identity");

               if Seen = 1 then
                  declare
                     Row : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 2));
                  begin
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Row)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Row) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Row)
                            = Landin.Types.Usize,
                        "the static array label carries field two's shape");
                  end;
                  declare
                     Repeated : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 5));
                     Mixed : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 6));
                  begin
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Repeated)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Repeated) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Repeated) = Landin.Types.U8
                        and then Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Mixed)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Mixed) = 3
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Mixed)
                            = Landin.Types.U16,
                        "static repetitions carry their field shapes");
                  end;
               elsif Seen = 4 then
                  declare
                     Row : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 1));
                     Ready : constant Landin.Syntax.Node_Id :=
                       Landin.Syntax.Value_Of
                         (Of_Tree.all,
                          Landin.Syntax.Nth_Field_Value
                            (Of_Tree.all, Node, 2));
                  begin
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Row)
                            = Landin.Types.Fixed_Array
                        and then Landin.Checking.Array_Length
                          (Types.all, Of_Tree.all, Row) = 2
                        and then Landin.Checking.Array_Element
                          (Types.all, Of_Tree.all, Row)
                            = Landin.Types.Usize,
                        "the array label carries field two's whole shape");
                     Landin.Testing.Check
                       (Item,
                        Landin.Checking.Type_Of
                          (Types.all, Of_Tree.all, Ready)
                            = Landin.Types.Bool,
                        "the zeroed label carries field three's scalar type");
                  end;
               end if;
            end if;
         end loop;
      end;

      Landin.Testing.Check_Equal
        (Item, Seen, 4, "all contextual struct literals were checked");
   end Struct_Literals_Carry_Body_And_Field_Identities;

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
        (Into, "checking", "array field assignment gives zeroed its shape",
         Array_Field_Assignment_Gives_Zeroed_Its_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "array field literals carry destination shape",
         Array_Field_Literals_Carry_Their_Destination_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "array field repetitions carry destination shape",
         Array_Field_Repetitions_Carry_Their_Destination_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "array-bearing struct copy uses each field fact",
         Array_Bearing_Struct_Copy_Uses_Each_Field_Fact'Access);
      Landin.Testing.Register
        (Into, "checking", "struct assignment gives zeroed its body",
         Struct_Assignment_Gives_Zeroed_Its_Body'Access);
      Landin.Testing.Register
        (Into, "checking", "local struct initializer keeps nominal source",
         Local_Struct_Initializer_Keeps_Its_Nominal_Source'Access);
      Landin.Testing.Register
        (Into, "checking", "module struct zeroed keeps nominal body",
         Module_Struct_Zeroed_Keeps_Its_Nominal_Body'Access);
      Landin.Testing.Register
        (Into, "checking", "module struct image chains keep nominal body",
         Module_Struct_Image_Chains_Keep_Their_Nominal_Body'Access);
      Landin.Testing.Register
        (Into, "checking", "inferred local struct keeps nominal source",
         Inferred_Local_Struct_Keeps_Its_Nominal_Source'Access);
      Landin.Testing.Register
        (Into, "checking", "array field copy uses whole field facts",
         Array_Field_Copy_Uses_Whole_Field_Facts'Access);
      Landin.Testing.Register
        (Into, "checking", "array field initializers carry source shape",
         Array_Field_Initializers_Carry_Their_Source_Shape'Access);
      Landin.Testing.Register
        (Into, "checking", "array extent follows usize",
         Array_Extent_Follows_Usize'Access);
      Landin.Testing.Register
        (Into, "checking", "struct array field extent follows usize",
         Struct_Array_Field_Extent_Follows_Usize'Access);
      Landin.Testing.Register
        (Into, "checking", "struct array field storage classes are enabled",
         Struct_Array_Field_Storage_Classes_Are_Enabled'Access);
      Landin.Testing.Register
        (Into, "checking", "struct literals carry body and field contexts",
         Struct_Literals_Carry_Body_And_Field_Identities'Access);
      Landin.Testing.Register
        (Into, "checking", "declared structs follow target layout",
         Declared_Structs_Follow_Target_Layout'Access);
   end Register;

end Landin.Tests.Checking_Suite;
