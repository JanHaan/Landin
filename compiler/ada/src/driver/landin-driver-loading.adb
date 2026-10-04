with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Containers.Vectors;
with Ada.Strings.Unbounded;

with Landin.Configuration;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Fixes;
with Landin.Diagnostics.Modules;
with Landin.Diagnostics.Resolution;
with Landin.Diagnostics.Suggestions;
with Landin.Modules;
with Landin.Source;
with Landin.Source.Names;
with Landin.Stages.Syntax;
with Landin.Syntax;
with Landin.Syntax.Forest;

package body Landin.Driver.Loading is

   package Unbounded renames Ada.Strings.Unbounded;
   package Module_Diagnostics renames Landin.Diagnostics.Modules;

   use type Landin.Modules.Module_Id;
   use type Landin.Platform.List_Status;
   use type Landin.Platform.Read_Status;
   use type Unbounded.Unbounded_String;

   package Module_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Landin.Modules.Module_Id);

   package Path_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   Code_Unreadable : constant Landin.Diagnostics.Code_String :=
     Landin.Diagnostics.Catalogue.Code
       (Landin.Diagnostics.Catalogue.Unreadable_Source);

   procedure Note_Failure
     (Context : in out Landin.Stages.Compilation; Text : String);

   procedure Note_Failure
     (Context : in out Landin.Stages.Compilation; Text : String) is
   begin
      Landin.Stages.Report
        (Context,
         Landin.Diagnostics.Make
           (Code    => Code_Unreadable,
            Level   => Landin.Diagnostics.Error,
            Source  => Landin.Source.No_Source,
            Where   => Landin.Source.Empty_Span,
            Message => Text));
   end Note_Failure;

   function Joined_Path (Directory, Child : String) return String is
     (if Directory'Length > 0
          and then Directory (Directory'Last) = '/'
      then Directory & Child
      else Directory & "/" & Child);

   function Is_Source_Name (Name : String) return Boolean is
     (Name'Length > 4
      and then Name (Name'Last - 3 .. Name'Last) = ".ldn");

   procedure Load_Files
     (Context : in out Landin.Stages.Compilation;
      Host    : Landin.Platform.Filesystem'Class;
      Paths   : Landin.Platform.Path_List)
   is
      Loaded    : Landin.Platform.Path_List;
      Unkeyed   : Landin.Platform.Path_List;
      Spellings : Path_Sets.Set;
      Keys      : Path_Sets.Set;

      function Already_Loaded (Path, Key : String) return Boolean;

      function Already_Loaded (Path, Key : String) return Boolean is
      begin
         if Key /= "" then
            if Keys.Contains (Key) then
               return True;
            end if;
            --  A host that could not key an earlier successful read may
            --  still prove this path aliases it by pairwise comparison.
            return (for some Previous of Unkeyed =>
                      Host.Same_File (Path, Previous));
         end if;
         return (for some Previous of Loaded =>
                   Host.Same_File (Path, Previous));
      end Already_Loaded;
   begin
      for Path of Paths loop
         if not Spellings.Contains (Path) then
            declare
               Key : constant String := Host.Existing_File_Key (Path);
            begin
               --  Preserve the first successful spelling and snapshot.
               --  Uncertain identities still take the ordinary read path.
               if not Already_Loaded (Path, Key) then
                  declare
                     Content : Unbounded.Unbounded_String;
                     Status  : Landin.Platform.Read_Status;
                  begin
                     Host.Read_File (Path, Content, Status);

                     case Status is
                        when Landin.Platform.Read_Ok =>
                           declare
                              Id : constant Landin.Source.Source_Id :=
                                Landin.Stages.Add_Source
                                  (Context, Path,
                                   Unbounded.To_String (Content));
                              pragma Unreferenced (Id);
                           begin
                              Loaded.Append (Path);
                              Spellings.Include (Path);
                              if Key = "" then
                                 Unkeyed.Append (Path);
                              else
                                 Keys.Include (Key);
                              end if;
                           end;

                        when Landin.Platform.Not_Found =>
                           Note_Failure
                             (Context, "source not found: " & Path);

                        when Landin.Platform.Not_Readable =>
                           Note_Failure
                             (Context,
                              "source not readable: " & Path);
                     end case;
                  end;
               end if;
            end;
         end if;
      end loop;
   end Load_Files;

   procedure Load_Reachable_Program
     (Context         : in out Landin.Stages.Compilation;
      Host            : Landin.Platform.Filesystem'Class;
      Roots           : Landin.Platform.Path_List;
      Entry_Directory : String;
      Missing_Directories : access Landin.Platform.Path_List := null;
      Previous        : access Landin.Stages.Compilation := null;
      Watch_Syntax    : access procedure (Name : String) := null)
   is
      type Directory_Listing is record
         Entries : Landin.Platform.Path_List;
         Status  : Landin.Platform.List_Status;
      end record;

      package Listing_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Directory_Listing);
      package Child_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Boolean);

      Listings : Listing_Maps.Map;
      Children : Child_Maps.Map;

      procedure Cached_Listing
        (Directory : String;
         Entries   : out Landin.Platform.Path_List;
         Status    : out Landin.Platform.List_Status);
      procedure Find_Child_Directory
        (Directory : String;
         Child     : String;
         Found     : out Boolean;
         Status    : out Landin.Platform.List_Status);

      procedure Cached_Listing
        (Directory : String;
         Entries   : out Landin.Platform.Path_List;
         Status    : out Landin.Platform.List_Status)
      is
      begin
         if Listings.Contains (Directory) then
            declare
               Saved : constant Directory_Listing :=
                 Listings.Element (Directory);
            begin
               Entries := Saved.Entries;
               Status := Saved.Status;
            end;
         else
            Host.List_Directory (Directory, Entries, Status);
            Listings.Insert (Directory, (Entries, Status));
         end if;
      end Cached_Listing;

      --  Include the parent's exact spelling in the key: distinct root
      --  spellings can produce the same joined child path.  Cache successful
      --  parent lookups only; a failed listing keeps its status in Listings.
      procedure Find_Child_Directory
        (Directory : String;
         Child     : String;
         Found     : out Boolean;
         Status    : out Landin.Platform.List_Status)
      is
         Path : constant String := Joined_Path (Directory, Child);
         Key  : constant String :=
           Natural'Image (Directory'Length) & ":" & Directory & Child;
      begin
         Status := Landin.Platform.List_Ok;
         if Children.Contains (Key) then
            Found := Children.Element (Key);
            return;
         end if;

         declare
            Entries : Landin.Platform.Path_List;
         begin
            Cached_Listing (Directory, Entries, Status);
            Found := False;
            if Status /= Landin.Platform.List_Ok then
               return;
            end if;
            for Child_Name of Entries loop
               if Child_Name = Child then
                  Found := Host.Is_Directory (Path);
                  exit;
               end if;
            end loop;
            Children.Insert (Key, Found);
         end;
      end Find_Child_Directory;

      function Import_Path
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id) return String;
      function Select_Module_Directory
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id;
         Root_At : out Natural;
         Unlistable : out Unbounded.Unbounded_String) return String;

      function Import_Path
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id) return String
      is
         Built : Unbounded.Unbounded_String;
      begin
         for Position in
           1 .. Landin.Syntax.Import_Segment_Count (Of_Tree, Node)
         loop
            if Position > 1 then
               Unbounded.Append (Built, "/");
            end if;
            Unbounded.Append
              (Built,
               Landin.Source.Names.Spelling
                 (Landin.Stages.Identities (Context).all,
                  Landin.Syntax.Name
                    (Of_Tree,
                     Landin.Syntax.Nth_Import_Segment
                       (Of_Tree, Node, Position))));
         end loop;
         return Unbounded.To_String (Built);
      end Import_Path;

      --  Check each path segment against the directory's listed spelling.
      --  This makes a case-insensitive host obey [1420]'s portable exact
      --  lowercase identity instead of accepting a differently cased entry.
      function Select_Module_Directory
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id;
         Root_At : out Natural;
         Unlistable : out Unbounded.Unbounded_String) return String
      is
      begin
         Root_At := 0;
         Unlistable := Unbounded.Null_Unbounded_String;
         for Root_Index in 1 .. Natural (Roots.Length) loop
            declare
               Current : Unbounded.Unbounded_String :=
                 Unbounded.To_Unbounded_String (Roots.Element (Root_Index));
               Matched : Boolean := True;
            begin
               for Position in
                 1 .. Landin.Syntax.Import_Segment_Count (Of_Tree, Node)
               loop
                  declare
                     Segment : constant String :=
                       Landin.Source.Names.Spelling
                         (Landin.Stages.Identities (Context).all,
                          Landin.Syntax.Name
                            (Of_Tree,
                             Landin.Syntax.Nth_Import_Segment
                               (Of_Tree, Node, Position)));
                     Status  : Landin.Platform.List_Status;
                     Found   : Boolean := False;
                  begin
                     Find_Child_Directory
                       (Unbounded.To_String (Current), Segment,
                        Found, Status);
                     if Status = Landin.Platform.Directory_Not_Readable then
                        Unlistable := Current;
                        return "";
                     end if;
                     if Status /= Landin.Platform.List_Ok then
                        Matched := False;
                        exit;
                     end if;
                     if not Found then
                        Matched := False;
                        exit;
                     end if;
                     Current := Unbounded.To_Unbounded_String
                       (Joined_Path
                          (Unbounded.To_String (Current), Segment));
                  end;
               end loop;
               if Matched then
                  Root_At := Root_Index;
                  return Unbounded.To_String (Current);
               end if;
            end;
         end loop;
         return "";
      end Select_Module_Directory;

      --  [1420]: the import names no directory under any root, so its
      --  first segment that no root holds is a misspelling of a
      --  directory that is there.  Every root is listed at that depth,
      --  in the roots' order and each listing in its sorted order, so
      --  the same tree always gets the same suggestion; only a name a
      --  module could have, a directory with an identifier's spelling,
      --  is offered.
      function Modules_Near
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id)
         return Landin.Diagnostics.Fix_List;

      function Modules_Near
        (Of_Tree : Landin.Syntax.Tree;
         Node    : Landin.Syntax.Node_Id)
         return Landin.Diagnostics.Fix_List
      is
         Count : constant Natural :=
           Landin.Syntax.Import_Segment_Count (Of_Tree, Node);
         Reached : Landin.Platform.Path_List := Roots;

         function Segment (Position : Positive) return String
           is (Landin.Source.Names.Spelling
                 (Landin.Stages.Identities (Context).all,
                  Landin.Syntax.Name
                    (Of_Tree,
                     Landin.Syntax.Nth_Import_Segment
                       (Of_Tree, Node, Position))));

         function Could_Name (Entry_Name : String) return Boolean
           is (Entry_Name'Length > 0
               and then Entry_Name (Entry_Name'First) in 'a' .. 'z'
               and then (for all C of Entry_Name =>
                           C in 'a' .. 'z' | '0' .. '9' | '_'));
      begin
         for Position in 1 .. Count loop
            declare
               Written : constant String := Segment (Position);
               Deeper  : Landin.Platform.Path_List;
               Offered : Landin.Diagnostics.Suggestions.Ranking;
            begin
               for Directory of Reached loop
                  declare
                     Entries : Landin.Platform.Path_List;
                     Status  : Landin.Platform.List_Status;
                  begin
                     Cached_Listing (Directory, Entries, Status);
                     if Status = Landin.Platform.List_Ok then
                        for Child_Name of Entries loop
                           if Child_Name = Written then
                              Deeper.Append
                                (Joined_Path (Directory, Child_Name));
                           elsif Could_Name (Child_Name)
                             and then Host.Is_Directory
                               (Joined_Path (Directory, Child_Name))
                           then
                              Landin.Diagnostics.Suggestions.Consider
                                (Offered, Written, Child_Name);
                           end if;
                        end loop;
                     end if;
                  end;
               end loop;

               if Deeper.Is_Empty then
                  return Landin.Diagnostics.Fixes.Respellings
                    (Landin.Syntax.Source_Of (Of_Tree),
                     Landin.Syntax.Anchor
                       (Of_Tree,
                        Landin.Syntax.Nth_Import_Segment
                          (Of_Tree, Node, Position)),
                     Offered);
               end if;
               Reached := Deeper;
            end;
         end loop;
         return Landin.Diagnostics.No_Fixes;
      end Modules_Near;
      Graph : constant not null access Landin.Modules.Table :=
        Landin.Stages.Modules (Context);
      Queue : Module_Vectors.Vector;
      Next  : Positive := 1;

      function Loaded_Directory (Path : String)
        return Landin.Modules.Module_Id;

      function Loaded_Directory (Path : String)
        return Landin.Modules.Module_Id
      is
         Exact : constant Landin.Modules.Module_Id :=
           Landin.Modules.Find_Directory (Graph.all, Path);
      begin
         if Exact /= Landin.Modules.No_Module then
            return Exact;
         end if;
         --  Preserve the first spelling for reads and diagnostics.
         --  Only the filesystem can prove that another spelling names
         --  the same directory; uncertain identities stay apart.
         for Position in 1 .. Landin.Modules.Module_Count (Graph.all)
         loop
            declare
               Candidate : constant Landin.Modules.Module_Id :=
                 Landin.Modules.Module_Id (Position);
            begin
               if Host.Same_File
                 (Path, Landin.Modules.Directory_Path
                    (Graph.all, Candidate))
               then
                  return Candidate;
               end if;
            end;
         end loop;
         return Landin.Modules.No_Module;
      end Loaded_Directory;
   begin
      if not Host.Is_Directory (Entry_Directory) then
         declare
            Found : Landin.Diagnostics.Diagnostic_List;
         begin
            Module_Diagnostics.Report
              (Item    => Module_Diagnostics.Module_Directory_Invalid,
               Source  => Landin.Source.No_Source,
               Where   => Landin.Source.Empty_Span,
               Message => "entry module is not a directory: "
                          & Entry_Directory,
               Note    => "[1410]: a module is one directory",
               Into    => Found);
            Landin.Stages.Report
              (Context, Landin.Diagnostics.Get (Found, 1));
         end;
         return;
      end if;

      Landin.Modules.Set_Entry_Directory
        (Graph.all, Entry_Directory);
      Queue.Append (Landin.Modules.Entry_Module);

      while Next <= Natural (Queue.Length) loop
         declare
            Module : constant Landin.Modules.Module_Id :=
              Queue.Element (Next);
            Directory : constant String :=
              Landin.Modules.Directory_Path (Graph.all, Module);
            Entries : Landin.Platform.Path_List;
            Listed  : Landin.Platform.List_Status;
            First_New : constant Natural :=
              Landin.Stages.Source_Count (Context) + 1;
         begin
            Host.List_Directory (Directory, Entries, Listed);
            if Listed /= Landin.Platform.List_Ok then
               declare
                  Found : Landin.Diagnostics.Diagnostic_List;
               begin
                  Module_Diagnostics.Report
                    (Item    =>
                       Module_Diagnostics.Module_Directory_Invalid,
                     Source  => Landin.Source.No_Source,
                     Where   => Landin.Source.Empty_Span,
                     Message => "module directory cannot be listed: "
                                & Directory,
                     Note    => "[1410]: a module is one readable"
                                & " directory",
                     Into    => Found);
                  Landin.Stages.Report
                    (Context, Landin.Diagnostics.Get (Found, 1));
               end;
               return;
            end if;

            for Child_Name of Entries loop
               declare
                  Path : constant String :=
                    Joined_Path (Directory, Child_Name);
               begin
                  if Is_Source_Name (Child_Name)
                    and then not Host.Is_Directory (Path)
                  then
                     declare
                        Content : Unbounded.Unbounded_String;
                        Status  : Landin.Platform.Read_Status;
                     begin
                        Host.Read_File (Path, Content, Status);
                        if Status = Landin.Platform.Read_Ok then
                           declare
                              Id : constant Landin.Source.Source_Id :=
                                Landin.Stages.Add_Source
                                  (Context, Module, Path,
                                   Unbounded.To_String (Content));
                              pragma Unreferenced (Id);
                           begin
                              null;
                           end;
                        elsif Status = Landin.Platform.Not_Found then
                           Note_Failure
                             (Context,
                              "source not found: " & Path);
                        else
                           Note_Failure
                             (Context,
                              "source not readable: " & Path);
                        end if;
                     end;
                  end if;
               end;
            end loop;

            if Landin.Stages.Source_Count (Context) >= First_New then
               declare
                  Syntax_Outcome : Landin.Stages.Stage_Outcome;
               begin
                  Landin.Stages.Syntax.Run_Using
                    (Context, Syntax_Outcome, Previous, Watch_Syntax);
               end;
            end if;
            exit when Landin.Stages.Failed (Context);

            for Source_Index in First_New
              .. Landin.Stages.Source_Count (Context)
            loop
               declare
                  Source_Id : constant Landin.Source.Source_Id :=
                    Landin.Stages.Nth_Source (Context, Source_Index);
                  Tree : constant not null access constant
                    Landin.Syntax.Tree :=
                      Landin.Syntax.Forest.Tree_Of
                        (Landin.Stages.Trees (Context).all, Source_Id);
               begin
                  for Import_Index in
                    1 .. Landin.Syntax.Import_Count (Tree.all)
                  loop
                     declare
                        Import_Node : constant Landin.Syntax.Node_Id :=
                          Landin.Syntax.Nth_Import
                            (Tree.all, Import_Index);
                        Logical : constant String :=
                          Import_Path (Tree.all, Import_Node);
                        Target : Landin.Modules.Module_Id :=
                          Landin.Modules.Find_Logical
                            (Graph.all, Logical);
                     begin
                        --  Rooted discovery refuses builtins before
                        --  any host lookup. Configuration shares this
                        --  predicate for explicit-file requests.
                        if Landin.Configuration.Is_Builtin_Import
                          (Landin.Stages.Identities (Context).all,
                           Tree.all, Import_Node)
                        then
                           declare
                              Found : Landin.Diagnostics.Diagnostic_List;
                           begin
                              Landin.Diagnostics.Resolution.Report
                                (Item => Landin.Diagnostics.Resolution
                                   .Reserved_Tool_Name,
                                 Source => Source_Id,
                                 Where => Landin.Syntax.Where
                                   (Tree.all, Import_Node),
                                 Message => "builtin module cannot be"
                                   & " explicitly imported: " & Logical,
                                 Note => "[1560]: compiler, assembler"
                                   & " and linker are in scope"
                                   & " without imports",
                                 Into => Found);
                              Landin.Stages.Report (Context,
                                Landin.Diagnostics.Get (Found, 1));
                           end;
                        elsif Target = Landin.Modules.No_Module then
                           declare
                              Selected_Root : Natural;
                              Unlistable : Unbounded.Unbounded_String;
                              Directory_Path : constant String :=
                                Select_Module_Directory
                                  (Tree.all, Import_Node,
                                   Selected_Root, Unlistable);
                           begin
                              if Unlistable /=
                                Unbounded.Null_Unbounded_String
                              then
                                 declare
                                    Found : Landin.Diagnostics
                                      .Diagnostic_List;
                                 begin
                                    Module_Diagnostics.Report
                                      (Item    => Module_Diagnostics
                                         .Module_Directory_Invalid,
                                       Source  => Source_Id,
                                       Where   => Landin.Syntax.Where
                                         (Tree.all, Import_Node),
                                       Message => "import directory cannot"
                                         & " be listed: "
                                         & Unbounded.To_String (Unlistable),
                                       Note    => "[1420]: roots are"
                                         & " searched in supplied order",
                                       Into    => Found);
                                    Landin.Stages.Report
                                      (Context,
                                       Landin.Diagnostics.Get (Found, 1));
                                 end;
                              elsif Directory_Path = "" then
                                 if Missing_Directories /= null then
                                    for Root of Roots loop
                                       Missing_Directories.Append
                                         (Joined_Path (Root, Logical));
                                    end loop;
                                 end if;
                                 declare
                                    Found : Landin.Diagnostics
                                      .Diagnostic_List;
                                 begin
                                    Module_Diagnostics.Report
                                      (Item    => Module_Diagnostics
                                         .Module_Not_Found,
                                       Source  => Source_Id,
                                       Where   => Landin.Syntax.Where
                                         (Tree.all, Import_Node),
                                       Message => "module not found: "
                                                  & Logical,
                                       Note    => "[1420]: roots are"
                                                  & " searched in"
                                                  & " supplied order",
                                       Fixes   => Modules_Near
                                         (Tree.all, Import_Node),
                                       Into    => Found);
                                    Landin.Stages.Report
                                      (Context,
                                       Landin.Diagnostics.Get
                                         (Found, 1));
                                 end;
                              else
                                 Target := Loaded_Directory
                                   (Directory_Path);
                                 if Target
                                   = Landin.Modules.No_Module
                                 then
                                    Target := Landin.Modules.Add_Module
                                      (Graph.all, Logical,
                                       Directory_Path,
                                       Positive (Selected_Root));
                                    Queue.Append (Target);
                                 end if;
                              end if;
                           end;
                        end if;
                        if Target /= Landin.Modules.No_Module then
                           Landin.Modules.Record_Import
                             (Graph.all, Source_Id, Import_Node, Target);
                        end if;
                     end;
                  end loop;
               end;
            end loop;
         end;
         Next := Next + 1;
      end loop;
   end Load_Reachable_Program;

end Landin.Driver.Loading;
