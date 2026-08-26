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
   use type Landin.Source.Source_Id;
   use type Landin.Syntax.Node_Id;
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

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "checking", "declarations give structs their identity",
         Declarations_Give_Structs_Their_Identity'Access);
      Landin.Testing.Register
        (Into, "checking", "array types are their length and element",
         Array_Types_Are_Their_Length_And_Element'Access);
      Landin.Testing.Register
        (Into, "checking", "declared structs follow target layout",
         Declared_Structs_Follow_Target_Layout'Access);
   end Register;

end Landin.Tests.Checking_Suite;
