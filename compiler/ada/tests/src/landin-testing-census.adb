with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Directories;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Ada.Text_IO;

with Landin.Checking;
with Landin.Library;
with Landin.Platform;
with Landin.Platform.Native;
with Landin.Resolution;
with Landin.Server.Analysis;
with Landin.Source;
with Landin.Source.Names;
with Landin.Stages;
with Landin.Syntax;
with Landin.Syntax.Forest;
with Landin.Targets;
with Landin.Targets.Levels;
with Landin.Targets.Selection;
with Landin.Testing.Fixtures;
with Landin.Tokens;
with Landin.Types;

package body Landin.Testing.Census is

   package Fixtures renames Landin.Testing.Fixtures;
   package Syntax renames Landin.Syntax;
   package Text_IO renames Ada.Text_IO;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Resolution.Declaration_Id;
   use type Landin.Resolution.Verdict;
   use type Landin.Source.Names.Name_Id;
   use type Landin.Tokens.Assignment_Operator;
   use type Landin.Types.Type_Kind;
   use type Syntax.Node_Id;
   use type Syntax.Node_Kind;

   Corpus   : constant String := "../tests/fixtures";
   Examples : constant String := "../../examples";

   --  Where a counted file lives.  The library is what `Landin.Library`
   --  finds; examples/ is the derived programs; the rest is the corpus.
   type Population is (Library, Example, Fixture);

   --  Constructs an audit of the language weighed that grep cannot count,
   --  or counts only roughly, each labelled with the paragraph defining it.
   type Construct is
     (Array_Operator, Array_Updating_Assignment, Self_Reading_Aggregate,
      Break_With_Value, Complete_Block, Labelled_Statement,
      Anonymous_Function, Try_For, Selected_Import,
      Uncounted_Repetition, Mixed_Repetition, Struct_Fill_Zeroed,
      Struct_Fill_Other, Range_Subtype, Inclusive_For, Inclusive_Slice,
      Hexadecimal_Float);

   function Label (Item : Construct) return String is
     (case Item is
         when Array_Operator =>
           "[0590] operator on whole arrays",
         when Array_Updating_Assignment =>
           "[0590] updating assignment of an array",
         when Self_Reading_Aggregate =>
           "[0520] aggregate assigned to a place it reads",
         when Break_With_Value => "[1190] break with",
         when Complete_Block => "[1170] complete",
         when Labelled_Statement => "[1180] labelled loop or block",
         when Anonymous_Function => "[1010] anonymous function",
         when Try_For => "[1320] try for",
         when Selected_Import => "[1440] import m (names)",
         when Uncounted_Repetition => "[0560] [of v]",
         when Mixed_Repetition => "[0560] [e1, ..., of v]",
         when Struct_Fill_Zeroed => "[0720] struct literal of zeroed",
         when Struct_Fill_Other => "[0720] struct literal of another value",
         when Range_Subtype => "[0660] range subtype",
         when Inclusive_For => "[0360] for over a .. b",
         when Inclusive_Slice => "[0360] slice a .. b",
         when Hexadecimal_Float => "[0230] hexadecimal float");

   --  Where each one stands is listed for the library and the examples,
   --  whose uses are what a removal rewrites; the corpus only counts.
   Listed : constant array (Construct) of Boolean :=
     [Array_Operator | Array_Updating_Assignment | Self_Reading_Aggregate
        | Break_With_Value | Complete_Block | Labelled_Statement
        | Hexadecimal_Float => True,
      others => False];

   Core_Part     : aliased constant String := "core";
   Hosted_Part   : aliased constant String := "hosted";
   Platform_Part : aliased constant String := "platform";
   Library_Parts : constant array (1 .. 3) of access constant String :=
     [Core_Part'Access, Hosted_Part'Access, Platform_Part'Access];

   type Tally is array (Construct, Population) of Natural;
   type Kind_Tally is array (Syntax.Node_Kind, Population) of Natural;

   package Path_Sets is new Ada.Containers.Indefinite_Ordered_Sets (String);

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Without_Slash (Path : String) return String is
     (if Path'Length > 1 and then Path (Path'Last) = '/'
      then Path (Path'First .. Path'Last - 1) else Path);

   function Image (Value : Natural) return String is
     (Ada.Strings.Fixed.Trim (Natural'Image (Value), Ada.Strings.Both));

   function Padded (Text : String; Width : Positive) return String is
     (if Text'Length >= Width then Text
      else Text & [1 .. Width - Text'Length => ' ']);

   function Right (Text : String; Width : Positive) return String is
     (if Text'Length >= Width then Text
      else [1 .. Width - Text'Length => ' '] & Text);

   procedure Run (Ok : out Boolean) is
      Real     : aliased Landin.Platform.Native.Native_Filesystem;
      Located  : constant String := Landin.Library.Located (Real);
      Library_Root : constant String :=
        Without_Slash
          (if Located /= "" and then Ada.Directories.Exists (Located)
           then Ada.Directories.Full_Name (Located) else Located);
      Example_Root : constant String :=
        Without_Slash
          (if Ada.Directories.Exists (Examples)
           then Ada.Directories.Full_Name (Examples) else "");
      Catalogue : Fixtures.Catalogue;
      Seen      : Path_Sets.Set;
      Counts    : Tally := [others => [others => 0]];
      Kinds     : Kind_Tally := [others => [others => 0]];
      Files     : array (Population) of Natural := [others => 0];
      Checked, Unchecked : Natural := 0;
      Places    : Unbounded.Unbounded_String;
      --  The program being checked, and those that could not be.
      Current, Refused : Unbounded.Unbounded_String;

      function Population_Of (Path : String) return Population is
        (if Library_Root /= ""
           and then (for some Part of Library_Parts =>
                       Starts_With (Path, Library_Root & "/" & Part.all & "/"))
         then Library
         elsif Example_Root /= ""
           and then Starts_With (Path, Example_Root & "/")
         then Example
         else Fixture);

      procedure Count_Source
        (Context : in out Landin.Stages.Compilation;
         Id      : Landin.Source.Source_Id);

      procedure Count_Source
        (Context : in out Landin.Stages.Compilation;
         Id      : Landin.Source.Source_Id)
      is
         --  A fixture may root a module in the repository through its
         --  own directory, `runtime/x/../../../../..`, so a file is known
         --  by its normalized full name and not by its spelling.
         Spelled : constant String :=
           Landin.Source.Name (Landin.Stages.Source (Context, Id));
         Path : constant String :=
           (if Ada.Directories.Exists (Spelled)
            then Ada.Directories.Full_Name (Spelled) else Spelled);
         Text : constant String :=
           Landin.Source.Text (Landin.Stages.Source (Context, Id));
         Where_From : constant Population := Population_Of (Path);
         Forest : constant not null access Landin.Syntax.Forest.Table :=
           Landin.Stages.Trees (Context);
         Typed  : constant not null access Landin.Checking.Table :=
           Landin.Stages.Types (Context);
         Meant  : constant not null access Landin.Resolution.Table :=
           Landin.Stages.Meanings (Context);
      begin
         if Seen.Contains (Path)
           or else not Landin.Syntax.Forest.Contains (Forest.all, Id)
         then
            return;
         end if;
         Seen.Insert (Path);
         Files (Where_From) := Files (Where_From) + 1;

         declare
            Tree : Syntax.Tree renames
              Landin.Syntax.Forest.Tree_Of (Forest.all, Id).all;
            Has_Types : constant Boolean :=
              Landin.Checking.Covers (Typed.all, Tree);
            Has_Meanings : constant Boolean :=
              Landin.Resolution.Covers (Meant.all, Tree);

            function Type_Of (Node : Syntax.Node_Id)
              return Landin.Types.Type_Kind is
              (if Has_Types and then Node /= Syntax.No_Node
               then Landin.Checking.Type_Of (Typed.all, Tree, Node)
               else Landin.Types.Undecided);

            function Is_Array (Node : Syntax.Node_Id) return Boolean is
              (Type_Of (Node) = Landin.Types.Fixed_Array);

            function Line_Of (Node : Syntax.Node_Id) return Positive;

            function Line_Of (Node : Syntax.Node_Id) return Positive is
               First : constant Natural :=
                 Natural (Syntax.Anchor (Tree, Node).First);
               Line : Positive := 1;
            begin
               for Index in Text'First .. Text'First + First - 1 loop
                  exit when Index > Text'Last;
                  if Text (Index) = ASCII.LF then
                     Line := Line + 1;
                  end if;
               end loop;
               return Line;
            end Line_Of;

            procedure Note (Item : Construct; Node : Syntax.Node_Id);

            procedure Note (Item : Construct; Node : Syntax.Node_Id) is
            begin
               Counts (Item, Where_From) := Counts (Item, Where_From) + 1;
               if Listed (Item) and then Where_From /= Fixture then
                  Unbounded.Append
                    (Places, "  " & Padded (Label (Item), 46) & " "
                     & Path & ":" & Image (Line_Of (Node)) & ASCII.LF);
               end if;
            end Note;

            --  The variable a place is written into: the name under its
            --  selections and indexes, or none for a place through a call
            --  or a pointer it does not name.
            function Root_Of (Place : Syntax.Node_Id)
              return Landin.Resolution.Declaration_Id;

            function Root_Of (Place : Syntax.Node_Id)
              return Landin.Resolution.Declaration_Id
            is
               Node : Syntax.Node_Id := Place;
            begin
               while Node /= Syntax.No_Node loop
                  case Syntax.Kind (Tree, Node) is
                     when Syntax.Name_Reference =>
                        if Has_Meanings
                          and then Landin.Resolution.Verdict_Of
                            (Meant.all, Tree, Node) = Landin.Resolution.Bound
                        then
                           return Landin.Resolution.Bound_To
                             (Meant.all, Tree, Node);
                        end if;
                        return Landin.Resolution.No_Declaration;
                     when Syntax.Member_Selection | Syntax.Element_Index =>
                        Node := Syntax.Target_Of (Tree, Node);
                     when others =>
                        return Landin.Resolution.No_Declaration;
                  end case;
               end loop;
               return Landin.Resolution.No_Declaration;
            end Root_Of;

            --  Whether a value's subtree names Variable.  A node's
            --  descendants are the nodes just before it in post-order,
            --  each inside its extent.
            function Reads
              (Value    : Syntax.Node_Id;
               Variable : Landin.Resolution.Declaration_Id) return Boolean;

            function Reads
              (Value    : Syntax.Node_Id;
               Variable : Landin.Resolution.Declaration_Id) return Boolean
            is
               Outer : constant Landin.Source.Span :=
                 Syntax.Where (Tree, Value);
               Node  : Syntax.Node_Id := Value;
            begin
               while Node > 1 loop
                  Node := Node - 1;
                  exit when not Landin.Source.Contains
                    (Outer, Syntax.Where (Tree, Node));
                  if Syntax.Kind (Tree, Node) = Syntax.Name_Reference
                    and then Landin.Resolution.Verdict_Of
                      (Meant.all, Tree, Node) = Landin.Resolution.Bound
                    and then Landin.Resolution.Bound_To
                      (Meant.all, Tree, Node) = Variable
                  then
                     return True;
                  end if;
               end loop;
               return False;
            end Reads;
         begin
            for Node in 1 .. Syntax.Last_Node (Tree) loop
               declare
                  Kind : constant Syntax.Node_Kind := Syntax.Kind (Tree, Node);
               begin
                  Kinds (Kind, Where_From) := Kinds (Kind, Where_From) + 1;
                  case Kind is
                     --  `lenof`, `addr` and the conversions take an array
                     --  without computing on its elements.
                     when Syntax.Negation | Syntax.Complement
                        | Syntax.Logical_Not =>
                        if Is_Array (Node)
                          or else Is_Array (Syntax.Operand_Of (Tree, Node))
                        then
                           Note (Array_Operator, Node);
                        end if;
                     when Syntax.Binary_Kind =>
                        if Is_Array (Node)
                          or else Is_Array (Syntax.Left_Of (Tree, Node))
                        then
                           Note (Array_Operator, Node);
                        end if;
                     when Syntax.Assignment =>
                        declare
                           Place : constant Syntax.Node_Id :=
                             Syntax.Target_Of (Tree, Node);
                           Value : constant Syntax.Node_Id :=
                             Syntax.Value_Of (Tree, Node);
                        begin
                           if Syntax.Assignment_Operation (Tree, Node)
                             /= Landin.Tokens.Plain_Assignment
                           then
                              if Is_Array (Place) then
                                 Note (Array_Updating_Assignment, Node);
                              end if;
                           elsif Has_Meanings
                             and then Value /= Syntax.No_Node
                             and then Syntax.Kind (Tree, Value)
                               in Syntax.Array_Literal
                                | Syntax.Array_Repetition
                                | Syntax.Mixed_Array_Repetition
                                | Syntax.Struct_Literal
                           then
                              declare
                                 Variable : constant
                                   Landin.Resolution.Declaration_Id :=
                                     Root_Of (Place);
                              begin
                                 if Variable
                                   /= Landin.Resolution.No_Declaration
                                   and then Reads (Value, Variable)
                                 then
                                    Note (Self_Reading_Aggregate, Node);
                                 end if;
                              end;
                           end if;
                        end;
                     when Syntax.Break_Statement =>
                        if Syntax.Transfer_Value (Tree, Node)
                          /= Syntax.No_Node
                        then
                           Note (Break_With_Value, Node);
                        end if;
                     when Syntax.Loop_Statement | Syntax.While_Statement
                        | Syntax.For_Statement | Syntax.Bare_Block =>
                        if Syntax.Name (Tree, Node)
                          /= Landin.Source.Names.No_Name
                        then
                           Note (Labelled_Statement, Node);
                        end if;
                        if Kind /= Syntax.Bare_Block
                          and then Syntax.Complete_Body (Tree, Node)
                            /= Syntax.No_Node
                        then
                           Note (Complete_Block, Node);
                        end if;
                        if Kind = Syntax.For_Statement then
                           if Syntax.Traversal_Propagates (Tree, Node) then
                              Note (Try_For, Node);
                           end if;
                           if Syntax.Traversal_Upper (Tree, Node)
                               /= Syntax.No_Node
                             and then Syntax.Traversal_Is_Inclusive
                               (Tree, Node)
                           then
                              Note (Inclusive_For, Node);
                           end if;
                        end if;
                     when Syntax.Anonymous_Function =>
                        Note (Anonymous_Function, Node);
                     when Syntax.Import_Declaration =>
                        if Syntax.Import_Selection_Count (Tree, Node) > 0 then
                           Note (Selected_Import, Node);
                        end if;
                     when Syntax.Array_Repetition =>
                        if Syntax.Repetition_Count (Tree, Node)
                          = Syntax.No_Node
                        then
                           Note (Uncounted_Repetition, Node);
                        end if;
                     when Syntax.Mixed_Array_Repetition =>
                        Note (Mixed_Repetition, Node);
                     when Syntax.Struct_Literal =>
                        declare
                           Fill : constant Syntax.Node_Id :=
                             Syntax.Struct_Fill (Tree, Node);
                        begin
                           if Fill = Syntax.No_Node then
                              null;
                           elsif Syntax.Kind (Tree, Fill)
                             = Syntax.Zeroed_Literal
                           then
                              Note (Struct_Fill_Zeroed, Node);
                           else
                              Note (Struct_Fill_Other, Node);
                           end if;
                        end;
                     when Syntax.Range_Subtype =>
                        Note (Range_Subtype, Node);
                     when Syntax.Inclusive_Slice =>
                        Note (Inclusive_Slice, Node);
                     when Syntax.Float_Literal =>
                        declare
                           At_Token : constant Landin.Source.Span :=
                             Syntax.Anchor (Tree, Node);
                           First : constant Natural :=
                             Text'First + Natural (At_Token.First);
                        begin
                           if First + 1 <= Text'Last
                             and then Text (First) = '0'
                             and then Text (First + 1) in 'x' | 'X'
                           then
                              Note (Hexadecimal_Float, Node);
                           end if;
                        end;
                     when others =>
                        null;
                  end case;
               end;
            end loop;
         end;
      end Count_Source;

      procedure Visit
        (Context : in out Landin.Stages.Compilation;
         Answer  : Landin.Server.Analysis.Result);

      procedure Visit
        (Context : in out Landin.Stages.Compilation;
         Answer  : Landin.Server.Analysis.Result) is
      begin
         if not Answer.Checked then
            Unchecked := Unchecked + 1;
            Unbounded.Append
              (Refused, "  " & Unbounded.To_String (Current) & ASCII.LF);
            return;
         end if;
         Checked := Checked + 1;
         for Index in 1 .. Landin.Stages.Source_Count (Context) loop
            Count_Source (Context, Landin.Stages.Nth_Source (Context, Index));
         end loop;
      end Visit;

      procedure Analyse
        (Asked : Landin.Server.Analysis.Request;
         Target_Name, Program : String);

      procedure Analyse
        (Asked : Landin.Server.Analysis.Request;
         Target_Name, Program : String)
      is
         Facts : constant Landin.Targets.Target_Facts :=
           (if Target_Name /= ""
              and then Landin.Targets.Selection.Is_Described (Target_Name)
            then Landin.Targets.Selection.Described (Target_Name)
            else Landin.Targets.Linux_X86_64);
      begin
         Current := Unbounded.To_Unbounded_String (Program);
         Landin.Server.Analysis.Analyse
           (Facts, Landin.Targets.Levels.Default_Level (Facts), Real, Asked,
            Visit'Access);
      end Analyse;

      --  The first of a fixture's comma-separated targets.
      function First_Target (Listed_Targets : String) return String;

      function First_Target (Listed_Targets : String) return String is
         Comma : constant Natural :=
           Ada.Strings.Fixed.Index (Listed_Targets, ",");
         Head  : constant String :=
           (if Comma = 0 then Listed_Targets
            else Listed_Targets (Listed_Targets'First .. Comma - 1));
      begin
         return Ada.Strings.Fixed.Trim (Head, Ada.Strings.Both);
      end First_Target;

      procedure Count_Library_Files
        (Directory : String; Total : in out Natural);

      procedure Count_Library_Files
        (Directory : String; Total : in out Natural)
      is
         use Ada.Directories;
         Search : Search_Type;
         Found  : Directory_Entry_Type;
      begin
         Start_Search (Search, Directory, "");
         while More_Entries (Search) loop
            Get_Next_Entry (Search, Found);
            declare
               Name : constant String := Simple_Name (Found);
            begin
               if Name = "." or else Name = ".." then
                  null;
               elsif Kind (Found) = Ada.Directories.Directory then
                  Count_Library_Files (Full_Name (Found), Total);
               elsif Name'Length > 4
                 and then Name (Name'Last - 3 .. Name'Last) = ".ldn"
               then
                  Total := Total + 1;
               end if;
            end;
         end loop;
         End_Search (Search);
      end Count_Library_Files;

      Library_Total : Natural := 0;
   begin
      Ok := Ada.Directories.Exists (Corpus);
      if not Ok then
         Text_IO.Put_Line
           (Text_IO.Standard_Error,
            "landin_tests --census must be run from compiler/ada");
         return;
      end if;

      Fixtures.Discover (Catalogue, Corpus, Real);
      for Index in 1 .. Fixtures.Count (Catalogue) loop
         declare
            Fixture : constant Fixtures.Fixture :=
              Fixtures.Nth (Catalogue, Index);
         begin
            if Fixtures.Class (Fixture)
                 in Fixtures.Positive_Program | Fixtures.Runtime
                  | Fixtures.Abi | Fixtures.Debugger | Fixtures.End_To_End
              and then Fixtures.Program (Fixture) /= ""
              and then Fixtures.Args (Fixture) = ""
            then
               declare
                  Arguments : Landin.Platform.Path_List;
                  Asked     : Landin.Server.Analysis.Request;
                  Rooted    : Boolean := False;
               begin
                  Asked.Library :=
                    Unbounded.To_Unbounded_String (Library_Root);
                  Fixtures.Append_Module_Arguments
                    (Fixture, Corpus, Arguments);
                  for Argument of Arguments loop
                     if Starts_With (Argument, "--root=") then
                        Asked.Roots.Append
                          (Argument (Argument'First + 7 .. Argument'Last));
                        Rooted := True;
                     elsif Rooted then
                        Asked.Entry_Directory :=
                          Unbounded.To_Unbounded_String (Argument);
                     else
                        Asked.Files.Append (Argument);
                     end if;
                  end loop;
                  Analyse
                    (Asked, First_Target (Fixtures.Targets (Fixture)),
                     Fixtures.Class_Directory (Fixtures.Class (Fixture))
                     & "/" & Fixtures.Name (Fixture));
               end;
            end if;
         end;
      end loop;

      if Library_Root /= "" then
         for Part of Library_Parts loop
            if Ada.Directories.Exists (Library_Root & "/" & Part.all) then
               Count_Library_Files
                 (Library_Root & "/" & Part.all, Library_Total);
            end if;
         end loop;
      end if;

      Text_IO.Put_Line
        ("census: " & Image (Checked) & " programs checked, "
         & Image (Unchecked) & " not checked and not counted");
      Text_IO.Put_Line
        ("files counted: library " & Image (Files (Library)) & " of "
         & Image (Library_Total) & ", examples " & Image (Files (Example))
         & ", corpus " & Image (Files (Fixture)));
      Text_IO.New_Line;
      Text_IO.Put_Line
        (Padded ("construct", 46) & Right ("library", 9)
         & Right ("examples", 9) & Right ("corpus", 9));
      for Item in Construct loop
         Text_IO.Put_Line
           (Padded (Label (Item), 46)
            & Right (Image (Counts (Item, Library)), 9)
            & Right (Image (Counts (Item, Example)), 9)
            & Right (Image (Counts (Item, Fixture)), 9));
      end loop;
      if Unchecked > 0 then
         Text_IO.New_Line;
         Text_IO.Put_Line ("not checked:");
         Text_IO.Put (Unbounded.To_String (Refused));
      end if;
      Text_IO.New_Line;
      Text_IO.Put_Line ("where, in the library and the examples:");
      Text_IO.Put (Unbounded.To_String (Places));
      Text_IO.New_Line;
      Text_IO.Put_Line ("every node kind written:");
      for Kind in Syntax.Node_Kind loop
         if Kinds (Kind, Library) + Kinds (Kind, Example)
           + Kinds (Kind, Fixture) > 0
         then
            Text_IO.Put_Line
              (Padded (Syntax.Node_Kind'Image (Kind), 46)
               & Right (Image (Kinds (Kind, Library)), 9)
               & Right (Image (Kinds (Kind, Example)), 9)
               & Right (Image (Kinds (Kind, Fixture)), 9));
         end if;
      end loop;
   end Run;

end Landin.Testing.Census;
