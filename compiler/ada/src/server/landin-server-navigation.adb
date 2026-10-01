with Ada.Strings.Unbounded;

with Landin.Checking;
with Landin.Checking.Spelling;
with Landin.Provenance;
with Landin.Resolution;
with Landin.Source.Names;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Types;

package body Landin.Server.Navigation is

   package Res renames Landin.Resolution;
   package Syn renames Landin.Syntax;
   package Ty renames Landin.Types;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Checking.Atom_Set_Id;
   use type Landin.Checking.Nominal_Type_Id;
   use type Landin.Checking.Reference_Id;
   use type Landin.Checking.Signature_Id;
   use type Landin.Checking.Progress;
   use type Landin.Provenance.Declaration_Id;
   use type Landin.Source.Byte_Offset;
   use type Res.Verdict;
   use type Syn.Node_Id;
   use type Ty.Type_Kind;

   function Doc_Comment
     (Text : String; Offset : Landin.Source.Byte_Offset) return String
   is
      --  Text is read as one-based for these indices.
      Bytes : constant String (1 .. Text'Length) := Text;
      Found : Unbounded.Unbounded_String;
      --  The first byte of the line being looked above.
      Start : Natural := Natural'Min (Natural (Offset), Bytes'Length) + 1;
   begin
      --  The start of the declaration's own line.
      while Start > 1 and then Bytes (Start - 1) not in ASCII.LF | ASCII.CR
      loop
         Start := Start - 1;
      end loop;

      while Start > 1 loop
         declare
            --  The line above ends before its terminator, LF, CR or CR LF.
            Stop  : Natural := Start - 1;
            First : Positive;
            Lead  : Positive;
         begin
            if Bytes (Stop) = ASCII.LF and then Stop > 1
              and then Bytes (Stop - 1) = ASCII.CR
            then
               Stop := Stop - 1;
            end if;
            Stop := Stop - 1;
            First := Stop + 1;
            while First > 1 and then Bytes (First - 1) not in ASCII.LF
                                                            | ASCII.CR
            loop
               First := First - 1;
            end loop;
            Lead := First;
            while Lead <= Stop and then Bytes (Lead) in ' ' | ASCII.HT loop
               Lead := Lead + 1;
            end loop;
            exit when Lead + 2 > Stop
              or else Bytes (Lead .. Lead + 2) /= "---"
              or else (Lead + 3 <= Stop and then Bytes (Lead + 3) = '(');
            declare
               From : constant Positive :=
                 (if Lead + 3 <= Stop and then Bytes (Lead + 3) = ' '
                  then Lead + 4 else Lead + 3);
               Line : constant String := Bytes (From .. Stop);
            begin
               Found := Unbounded.To_Unbounded_String
                 (if Unbounded.Length (Found) = 0 then Line
                  else Line & ASCII.LF & Unbounded.To_String (Found));
            end;
            Start := First;
         end;
      end loop;
      return Unbounded.To_String (Found);
   end Doc_Comment;

   --  The innermost node of Of_Tree whose extent holds Offset, preferring
   --  a name: nodes are in post-order, so a child comes before its parent
   --  and the first that holds Offset among the smallest is the innermost.
   function Node_At
     (Of_Tree : Syn.Tree; Offset : Landin.Source.Byte_Offset)
      return Syn.Node_Id;

   function Node_At
     (Of_Tree : Syn.Tree; Offset : Landin.Source.Byte_Offset)
      return Syn.Node_Id
   is
      Best   : Syn.Node_Id := Syn.No_Node;
      Length : Landin.Source.Byte_Offset := Landin.Source.Byte_Offset'Last;
   begin
      for Node in 1 .. Syn.Last_Node (Of_Tree) loop
         declare
            Where : constant Landin.Source.Span := Syn.Where (Of_Tree, Node);
         begin
            if Offset >= Where.First and then Offset < Where.Last
              and then Where.Last - Where.First < Length
              and then not Syn.Is_Error (Syn.Kind (Of_Tree, Node))
            then
               Best := Node;
               Length := Where.Last - Where.First;
            end if;
         end;
      end loop;
      return Best;
   end Node_At;

   --  The declaration a node names or declares, through the anchor it was
   --  found at: a reference must be bound, and a declaring node counts
   --  only when the offset is in its name.
   function Declaration_For
     (Context : in out Landin.Stages.Compilation;
      Of_Tree : Syn.Tree;
      Source  : Landin.Source.Source_Id;
      Node    : Syn.Node_Id;
      Offset  : Landin.Source.Byte_Offset) return Res.Declaration_Id;

   function Declaration_For
     (Context : in out Landin.Stages.Compilation;
      Of_Tree : Syn.Tree;
      Source  : Landin.Source.Source_Id;
      Node    : Syn.Node_Id;
      Offset  : Landin.Source.Byte_Offset) return Res.Declaration_Id
   is
      Meanings : constant not null access Res.Table :=
        Landin.Stages.Meanings (Context);
      Anchor   : constant Landin.Source.Span := Syn.Anchor (Of_Tree, Node);
   begin
      if not Res.Is_Prepared (Meanings.all)
        or else not Res.Covers (Meanings.all, Of_Tree)
      then
         return Res.No_Declaration;
      elsif Res.Verdict_Of (Meanings.all, Of_Tree, Node) = Res.Bound then
         return Res.Bound_To (Meanings.all, Of_Tree, Node);
      elsif Res.Declares (Syn.Kind (Of_Tree, Node))
        and then Offset >= Anchor.First and then Offset < Anchor.Last
      then
         return Res.Declaration_At (Meanings.all, Source, Node);
      end if;
      return Res.No_Declaration;
   end Declaration_For;

   function Definition
     (Context : in out Landin.Stages.Compilation;
      Answer  : Landin.Server.Analysis.Result;
      Source  : Landin.Source.Source_Id;
      Offset  : Landin.Source.Byte_Offset) return Place
   is
   begin
      if not Answer.Checked
        or else not Landin.Syntax.Forest.Contains
          (Landin.Stages.Trees (Context).all, Source)
        or else Landin.Server.Analysis.Is_Held
          (Answer, Source, (Offset, Offset))
      then
         return No_Place;
      end if;
      declare
         Of_Tree : constant not null access constant Syn.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Context).all, Source);
         Node : constant Syn.Node_Id := Node_At (Of_Tree.all, Offset);
      begin
         if Node = Syn.No_Node then
            return No_Place;
         end if;
         declare
            Id : constant Res.Declaration_Id :=
              Declaration_For (Context, Of_Tree.all, Source, Node, Offset);
            Sites : constant not null access Landin.Provenance.Table :=
              Landin.Stages.Sites (Context);
         begin
            if Id = Res.No_Declaration
              or else not Landin.Provenance.Contains (Sites.all, Id)
            then
               return No_Place;
            end if;
            declare
               Site : constant Landin.Provenance.Origin :=
                 Landin.Provenance.Site (Sites.all, Id);
            begin
               if not Landin.Provenance.Is_Known (Site)
                 or else Landin.Server.Analysis.Is_Held
                   (Answer, Site.Source, Site.Where)
               then
                  return No_Place;
               end if;
               return (Site.Source, Site.Where);
            end;
         end;
      end;
   end Definition;

   --  A type, as the checker spells one, from what the checking table
   --  holds for a node or a declaration; "" when it decided nothing a
   --  person could read.
   function Type_Text
     (Spelt     : Landin.Checking.Spelling.Tables;
      Kind      : Ty.Type_Kind;
      Nominal   : Landin.Checking.Nominal_Type_Id;
      Reference : Landin.Checking.Reference_Id;
      Atoms     : Landin.Checking.Atom_Set_Id;
      Signature : Landin.Checking.Signature_Id) return String;

   function Type_Text
     (Spelt     : Landin.Checking.Spelling.Tables;
      Kind      : Ty.Type_Kind;
      Nominal   : Landin.Checking.Nominal_Type_Id;
      Reference : Landin.Checking.Reference_Id;
      Atoms     : Landin.Checking.Atom_Set_Id;
      Signature : Landin.Checking.Signature_Id) return String
   is
      Types : Landin.Checking.Table renames Spelt.Types.all;
   begin
      case Kind is
         when Ty.Scalar_Name =>
            return Ty.Spelling (Kind);
         when Ty.Pointer_Value | Ty.Slice_Value | Ty.Any_Value =>
            if Reference /= Landin.Checking.No_Reference
              and then Landin.Checking.Holds (Types, Reference)
            then
               return Landin.Checking.Spelling.Reference_Text
                 (Spelt, Reference);
            end if;
         when Ty.Aggregate | Ty.Fixed_Array =>
            if Nominal /= Landin.Checking.No_Nominal_Type
              and then Landin.Checking.Holds (Types, Nominal)
            then
               return Landin.Checking.Spelling.Nominal_Text (Spelt, Nominal);
            end if;
         when Ty.Atom_Value =>
            if Atoms /= Landin.Checking.No_Atom_Set
              and then Landin.Checking.Holds (Types, Atoms)
            then
               return Landin.Checking.Spelling.Atoms_Text (Spelt, Atoms);
            end if;
         when Ty.Function_Value =>
            if Signature /= Landin.Checking.No_Signature then
               return "function";
            end if;
         when Ty.No_Value =>
            return "none";
         when others =>
            null;
      end case;
      return "";
   end Type_Text;

   --  A declaration, described: its kind and name with its type, or the
   --  header it is written with, then its doc comment.
   function Described
     (Context : in out Landin.Stages.Compilation;
      Spelt   : Landin.Checking.Spelling.Tables;
      Of_Tree : Syn.Tree;
      Node    : Syn.Node_Id;
      Id      : Res.Declaration_Id) return Description;

   function Described
     (Context : in out Landin.Stages.Compilation;
      Spelt   : Landin.Checking.Spelling.Tables;
      Of_Tree : Syn.Tree;
      Node    : Syn.Node_Id;
      Id      : Res.Declaration_Id) return Description
   is
      Meanings : Res.Table renames Spelt.Meanings.all;
      Types    : Landin.Checking.Table renames Spelt.Types.all;
      Name     : constant String := Landin.Source.Names.Spelling
        (Spelt.Spellings.all, Res.Name_Of (Meanings, Id));
      Home     : constant Landin.Source.Source_Id :=
        Res.Source_Of (Meanings, Id);
      Text     : constant String := Landin.Source.Text
        (Landin.Stages.Source (Context, Home).Element.all);
      Written  : constant Syn.Node_Id := Res.Node_Of (Meanings, Id);
      Home_Tree : constant not null access constant Syn.Tree :=
        Landin.Syntax.Forest.Tree_Of
          (Landin.Stages.Trees (Context).all, Home);
      Extent   : constant Landin.Source.Span :=
        Syn.Where (Home_Tree.all, Written);
      Shown    : Unbounded.Unbounded_String;

      --  The declaration's first line, as written: a routine's header and
      --  a type's or atom's whole declaration when it is one line.
      function First_Line return String;

      function First_Line return String is
         First : constant Positive := Text'First + Natural (Extent.First);
         Last  : Natural := First - 1;
      begin
         while Last + 1 <= Text'First + Natural (Extent.Last) - 1
           and then Text (Last + 1) not in ASCII.LF | ASCII.CR
         loop
            Last := Last + 1;
         end loop;
         --  A routine's `=` opens its body and says nothing about it.
         if Last - 1 >= First and then Text (Last - 1 .. Last) = " ="
         then
            Last := Last - 2;
         end if;
         return Text (First .. Last);
      end First_Line;

      function Typed return String is
        (if Landin.Checking.Contains (Types, Id)
           and then Landin.Checking.State_Of (Types, Id)
             = Landin.Checking.Settled
         then Type_Text
           (Spelt,
            Landin.Checking.Type_Of (Types, Id),
            Landin.Checking.Nominal_Of (Types, Id),
            Landin.Checking.Reference_Of (Types, Id),
            Landin.Checking.Atom_Set_Of (Types, Id),
            Landin.Checking.Signature_Of (Types, Id))
         else "");
   begin
      case Res.Sort_Of (Meanings, Id) is
         when Res.Module_Function | Res.Module_Type | Res.Module_Concept
            | Res.Module_Atom | Res.Case_Name =>
            Unbounded.Append (Shown, First_Line);
         when others =>
            declare
               Kind : constant String := Typed;
            begin
               if Kind = "" then
                  return (Length => 0, Range_Of => No_Place, Text => "");
               end if;
               Unbounded.Append (Shown, Name & ": " & Kind);
            end;
      end case;
      declare
         --  [2000]: a doc comment is about a declaration that begins its
         --  line, so a parameter on its routine's line has none.
         Line_Begins : Boolean := True;
      begin
         for Index in reverse
           Text'First .. Text'First + Natural (Extent.First) - 1
         loop
            exit when Text (Index) in ASCII.LF | ASCII.CR;
            if Text (Index) not in ' ' | ASCII.HT then
               Line_Begins := False;
            end if;
         end loop;
         if not Line_Begins then
            declare
               Markdown : constant String :=
                 "```landin" & ASCII.LF & Unbounded.To_String (Shown)
                 & ASCII.LF & "```";
            begin
               return (Length   => Markdown'Length,
                       Range_Of => (Syn.Source_Of (Of_Tree),
                                    Syn.Anchor (Of_Tree, Node)),
                       Text     => Markdown);
            end;
         end if;
      end;
      declare
         Doc : constant String := Doc_Comment (Text, Extent.First);
         Markdown : constant String :=
           "```landin" & ASCII.LF & Unbounded.To_String (Shown) & ASCII.LF
           & "```" & (if Doc = "" then "" else ASCII.LF & ASCII.LF & Doc);
      begin
         return (Length   => Markdown'Length,
                 Range_Of => (Syn.Source_Of (Of_Tree),
                              Syn.Anchor (Of_Tree, Node)),
                 Text     => Markdown);
      end;
   end Described;

   function Hover
     (Context : in out Landin.Stages.Compilation;
      Answer  : Landin.Server.Analysis.Result;
      Source  : Landin.Source.Source_Id;
      Offset  : Landin.Source.Byte_Offset) return Description
   is
      Nothing : constant Description := (Length => 0, Range_Of => No_Place,
                                         Text => "");
   begin
      if not Answer.Checked
        or else not Landin.Syntax.Forest.Contains
          (Landin.Stages.Trees (Context).all, Source)
        or else Landin.Server.Analysis.Is_Held
          (Answer, Source, (Offset, Offset))
      then
         return Nothing;
      end if;
      declare
         Of_Tree  : constant not null access constant Syn.Tree :=
           Landin.Syntax.Forest.Tree_Of
             (Landin.Stages.Trees (Context).all, Source);
         Node     : constant Syn.Node_Id := Node_At (Of_Tree.all, Offset);
         Types    : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Context);
         Meanings : constant not null access Res.Table :=
           Landin.Stages.Meanings (Context);
         Spellings : constant not null access Landin.Source.Names.Table :=
           Landin.Stages.Identities (Context);
         Spelt    : constant Landin.Checking.Spelling.Tables :=
           (Types => Types, Meanings => Meanings, Spellings => Spellings);
      begin
         if Node = Syn.No_Node
           or else not Landin.Checking.Is_Prepared (Types.all)
           or else not Landin.Checking.Covers (Types.all, Of_Tree.all)
         then
            return Nothing;
         end if;
         declare
            Id : constant Res.Declaration_Id :=
              Declaration_For (Context, Of_Tree.all, Source, Node, Offset);
         begin
            if Id /= Res.No_Declaration then
               return Described (Context, Spelt, Of_Tree.all, Node, Id);
            end if;
         end;
         --  An expression: its type, if the checker decided one.
         declare
            Kind : constant Ty.Type_Kind :=
              Landin.Checking.Type_Of (Types.all, Of_Tree.all, Node);
            Text : constant String := Type_Text
              (Spelt, Kind,
               Landin.Checking.Nominal_Of (Types.all, Of_Tree.all, Node),
               Landin.Checking.Reference_Of (Types.all, Of_Tree.all, Node),
               Landin.Checking.Atom_Set_Of (Types.all, Of_Tree.all, Node),
               Landin.Checking.Signature_Of (Types.all, Of_Tree.all, Node));
         begin
            if Text = "" or else Syn.Kind (Of_Tree.all, Node) not in
              Syn.Expression_Kind
            then
               return Nothing;
            end if;
            declare
               Shown : constant String := "```landin" & ASCII.LF & Text
                 & ASCII.LF & "```";
            begin
               return (Length   => Shown'Length,
                       Range_Of => (Source, Syn.Where (Of_Tree.all, Node)),
                       Text     => Shown);
            end;
         end;
      end;
   end Hover;

end Landin.Server.Navigation;
