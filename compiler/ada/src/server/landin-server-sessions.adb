with Ada.Strings.Fixed;
with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Finalization;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Landin.Configuration;
with Landin.Diagnostics;
with Landin.Driver.Library;
with Landin.Formatting;
with Landin.Json;
with Landin.Modules;
with Landin.Server.Analysis;
with Landin.Server.Answers;
with Landin.Server.Documents;
with Landin.Server.Positions;
with Landin.Server.Texts;
with Landin.Server.Transport;
with Landin.Source;
with Landin.Source.Sets;
with Landin.Stages;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Targets.Levels;
with Landin.Targets.Selection;

package body Landin.Server.Sessions is

   package Unbounded renames Ada.Strings.Unbounded;
   package Diag renames Landin.Diagnostics;
   package J renames Landin.Json;

   use type J.Value_Kind;
   use type Landin.Server.Transport.Status;
   use type Diag.Severity;
   use type Landin.Source.Source_Id;
   use type Landin.Server.Documents.Document;
   use type Landin.Platform.Read_Status;

   --  JSON-RPC's and the protocol's error codes.
   Parse_Error          : constant := -32700;
   Invalid_Request      : constant := -32600;
   Method_Not_Found     : constant := -32601;
   Invalid_Params       : constant := -32602;
   Internal_Error       : constant := -32603;
   Not_Initialized      : constant := -32002;

   package String_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   package Caches is
      subtype Compilation_Access is Landin.Server.Analysis.Compilation_Access;
      type Cached_Analysis is record
         Context : Compilation_Access;
         Answer  : Landin.Server.Analysis.Result;
      end record;
      type Analysis_Access is access Cached_Analysis;
      package Analysis_Maps is new Ada.Containers.Indefinite_Ordered_Maps
        (Key_Type => String, Element_Type => Analysis_Access);
      type Analysis_Cache is new Ada.Finalization.Limited_Controlled
      with record
         Entries : Analysis_Maps.Map;
      end record;

      procedure Drop (Item : in out Analysis_Access);
      procedure Remove (Cache : in out Analysis_Cache; Key : String);
      procedure Clear (Cache : in out Analysis_Cache);
      overriding procedure Finalize (Cache : in out Analysis_Cache);
   end Caches;

   package body Caches is
      procedure Free_Context (Context : in out Compilation_Access)
        renames Landin.Server.Analysis.Release;
      procedure Free_Entry is new Ada.Unchecked_Deallocation
        (Cached_Analysis, Analysis_Access);

      procedure Drop (Item : in out Analysis_Access) is
      begin
         if Item /= null then
            Free_Context (Item.Context);
            Free_Entry (Item);
         end if;
      end Drop;

      procedure Remove (Cache : in out Analysis_Cache; Key : String) is
      begin
         if Cache.Entries.Contains (Key) then
            declare
               Item : Analysis_Access := Cache.Entries.Element (Key);
            begin
               Cache.Entries.Delete (Key);
               Drop (Item);
            end;
         end if;
      end Remove;

      procedure Clear (Cache : in out Analysis_Cache) is
      begin
         while not Cache.Entries.Is_Empty loop
            Remove (Cache, Cache.Entries.First_Key);
         end loop;
      end Clear;

      overriding procedure Finalize (Cache : in out Analysis_Cache) is
      begin
         Clear (Cache);
      end Finalize;
   end Caches;

   use Caches;
   package Path_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => Landin.Server.Documents.Document);
   use type String_Sets.Set;

   package Set_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String_Sets.Set);

   function Starts (Text, Prefix : String) return Boolean
     is (Text'Length >= Prefix'Length
         and then Text (Text'First .. Text'First + Prefix'Length - 1)
           = Prefix);

   --  The text before a path's last '/', or "" for a path with none or
   --  with only the one it begins with.
   function Directory_Of (Path : String) return String;

   function Directory_Of (Path : String) return String is
      Slash : constant Natural :=
        Ada.Strings.Fixed.Index (Path, "/", Ada.Strings.Backward);
   begin
      return (if Slash > Path'First then Path (Path'First .. Slash - 1)
              else "");
   end Directory_Of;

   --  A set kept under a name, absent while it is empty.  Paths and module
   --  keys are whole strings here: a path may hold any byte but NUL, a
   --  line feed included, so no byte can join several into one text.
   procedure Add (Into : in out Set_Maps.Map; Name, Member : String);
   procedure Remove (From : in out Set_Maps.Map; Name, Member : String);
   function Members (From : Set_Maps.Map; Name : String)
     return String_Sets.Set;

   procedure Add (Into : in out Set_Maps.Map; Name, Member : String) is
      Position : constant Set_Maps.Cursor := Into.Find (Name);
   begin
      if Set_Maps.Has_Element (Position) then
         Into.Reference (Position).Include (Member);
      else
         Into.Insert (Name, String_Sets.To_Set (Member));
      end if;
   end Add;

   procedure Remove (From : in out Set_Maps.Map; Name, Member : String) is
      Position : Set_Maps.Cursor := From.Find (Name);
   begin
      if Set_Maps.Has_Element (Position) then
         From.Reference (Position).Exclude (Member);
         if From.Reference (Position).Is_Empty then
            From.Delete (Position);
         end if;
      end if;
   end Remove;

   function Members (From : Set_Maps.Map; Name : String)
     return String_Sets.Set
   is
      Position : constant Set_Maps.Cursor := From.Find (Name);
   begin
      return (if Set_Maps.Has_Element (Position)
              then Set_Maps.Element (Position) else String_Sets.Empty_Set);
   end Members;

   --  What the publications of one module in one round found, through each
   --  of its documents when it has several under one path.
   type Round is record
      --  Every source published, as the loader spelled its path.
      Paths    : String_Sets.Set;
      --  What a change on disk is compared with; see Watch_Path.
      Watched  : String_Sets.Set;
      --  Each report with no place in a source, as it is shown.
      Told     : String_Sets.Set;
      --  False once a publication ended in a defect: what it would have
      --  read is unknown, so nothing the module reported before is dropped.
      Complete : Boolean := True;
   end record;

   --  What a defect's message adds when the defect is the stack or the
   --  memory running out under one analysis (D1220), and "" otherwise.
   function Exhaustion
     (Error : Ada.Exceptions.Exception_Occurrence) return String;

   function Exhaustion
     (Error : Ada.Exceptions.Exception_Occurrence) return String
   is
      use type Ada.Exceptions.Exception_Id;
   begin
      return
        (if Ada.Exceptions.Exception_Identity (Error) = Storage_Error'Identity
         then ": it exhausted the stack or the memory the server has"
         else "");
   end Exhaustion;

   procedure Serve
     (Channel : in out Landin.Platform.Channel'Class;
      Host    : not null access constant Landin.Platform.Filesystem'Class;
      Status  : out Exit_Status;
      On_Analysis : access procedure := null;
      Statistics : access Publication_Statistics := null)
   is
      From      : Landin.Server.Transport.Reader;
      Store     : Landin.Server.Documents.Store (Host);
      Unit      : Positions.Encoding := Positions.UTF_16;
      --  D257: the compiler's own host, as `refine` defaults to, until the
      --  editor names a target.  A host no description covers starts on
      --  synthetic-32, which checks a program and emits nothing, and the
      --  editor is told to name one.
      Has_Default : constant Boolean :=
        Landin.Targets.Selection.Has_Host_Default
          (Landin.Targets.Selection.Build_Triplet);
      Facts     : Landin.Targets.Target_Facts :=
        (if Has_Default
         then Landin.Targets.Selection.Host_Default
                (Landin.Targets.Selection.Build_Triplet)
         else Landin.Targets.Synthetic_32);
      Level     : Landin.Targets.Levels.Feature_Level :=
        Landin.Targets.Levels.Default_Level (Facts);
      Options   : Landin.Platform.Path_List;
      Firmware_Entry : Unbounded.Unbounded_String;
      Started   : Boolean := False;
      Stopping  : Boolean := False;
      Watch_Registration_Offered : Boolean := False;
      --  Modules whose documents changed since they were last published.
      Stale     : String_Sets.Set;
      --  Every path each module's last report published to, so a path it
      --  no longer reports on is cleared, and its inverse.
      Published : Set_Maps.Map;
      Path_Users : Set_Maps.Map;
      --  What each module's last report rests on, as the tokens Watch_Path
      --  and Watch_Directory make, and its inverse: a change on disk makes
      --  stale the modules that watch what it names.
      Watched   : Set_Maps.Map;
      Watchers  : Set_Maps.Map;
      --  The reports with no place in a source that each module's last
      --  publication showed, so the next one does not show them again.
      Told      : Set_Maps.Map;
      --  Configured options already said to be unused by some module.
      Said_Unused : String_Sets.Set;
      Cached    : Analysis_Cache;

      procedure Send (Item : String);

      procedure Send (Item : String) is
      begin
         Channel.Write (Landin.Server.Transport.Framed (Item));
      end Send;

      --  A publication belongs to a path, even when several open entry
      --  modules read it.  Refresh another reporter instead of erasing its
      --  diagnostics when one module stops reporting that path.
      procedure Clear_Unless_Shared (Key, Path : String);

      procedure Clear_Unless_Shared (Key, Path : String) is
         Shared : Boolean := False;
      begin
         for User of Members (Path_Users, Path) loop
            if User /= Key then
               Shared := True;
               Stale.Include (User);
            end if;
         end loop;
         if not Shared then
            Send (Landin.Server.Answers.Cleared
              (Landin.Server.Documents.URI_For (Store, Path)));
         end if;
      end Clear_Unless_Shared;

      --  An id as written, to answer with: a number or a string.
      function Id_Text (Message : J.Document; Id : J.Value) return String
        is (if J.Is_Kind (Message, Id, J.String_Value)
            then J.Quoted (J.Text (Message, Id))
            elsif J.Is_Kind (Message, Id, J.Number_Value)
            then J.Text (Message, Id)
            else "null");

      procedure Respond (Id : String; Result : String);

      --  Assembled on the heap: a result may be a large file's edits, and
      --  a concatenation that long is built on the primary stack.
      procedure Respond (Id : String; Result : String) is
         Whole : Unbounded.Unbounded_String;
      begin
         Unbounded.Append
           (Whole, "{""jsonrpc"":""2.0"",""id"":" & Id & ",""result"":");
         Unbounded.Append (Whole, Result);
         Unbounded.Append (Whole, "}");
         Send (Unbounded.To_String (Whole));
      end Respond;

      procedure Refuse (Id : String; Code : Integer; Message : String);

      procedure Refuse (Id : String; Code : Integer; Message : String) is
         Written : J.Builder;
      begin
         J.Begin_Object (Written);
         J.Name (Written, "jsonrpc");
         J.Write_String (Written, "2.0");
         J.Name (Written, "id");
         J.Write_Raw (Written, Id);
         J.Name (Written, "error");
         J.Begin_Object (Written);
         J.Name (Written, "code");
         J.Write_Integer (Written, Long_Long_Integer (Code));
         J.Name (Written, "message");
         J.Write_String (Written, Message);
         J.End_Object (Written);
         J.End_Object (Written);
         Send (J.Result (Written));
      end Refuse;

      --  window/showMessage, for what belongs to no document, or
      --  window/logMessage, for what an editor keeps without interrupting.
      procedure Tell
        (Kind : Positive; Message : String; Shown : Boolean := True);

      procedure Tell
        (Kind : Positive; Message : String; Shown : Boolean := True)
      is
         Written : J.Builder;
      begin
         J.Begin_Object (Written);
         J.Name (Written, "jsonrpc");
         J.Write_String (Written, "2.0");
         J.Name (Written, "method");
         J.Write_String
           (Written,
            (if Shown then "window/showMessage" else "window/logMessage"));
         J.Name (Written, "params");
         J.Begin_Object (Written);
         J.Name (Written, "type");
         J.Write_Integer (Written, Long_Long_Integer (Kind));
         J.Name (Written, "message");
         J.Write_String (Written, Message);
         J.End_Object (Written);
         J.End_Object (Written);
         Send (J.Result (Written));
      end Tell;

      ------------------------------------------------------------------
      --  Analysis
      ------------------------------------------------------------------

      --  Switching aliases can change an imported overlay too, so invalidate
      --  all checked modules when activation selects different source bytes.
      procedure Activate (URI : String);

      procedure Activate (URI : String) is
         Changed : Boolean;
      begin
         Landin.Server.Documents.Activate (Store, URI, Changed);
         if Changed then
            Clear (Cached);
         end if;
      end Activate;

      --  Keep checked modules until a document changes or closes.
      procedure With_Analysis
        (URI   : String;
         Visit : not null access procedure
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result);
         Parse_Cache : access Landin.Stages.Syntax.Parse_Cache := null);

      procedure With_Analysis
        (URI   : String;
         Visit : not null access procedure
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result);
         Parse_Cache : access Landin.Stages.Syntax.Parse_Cache := null)
      is
         Key : constant String :=
           Landin.Server.Documents.Module_Key (Store, URI);
         Item : Analysis_Access;
         New_Entry : Boolean := False;
      begin
         Landin.Server.Documents.Flush (Store);
         Activate (URI);
         if Cached.Entries.Contains (Key) then
            Item := Cached.Entries.Element (Key);
         else
            Item := new Cached_Analysis;
            New_Entry := True;
            declare
               Asked : Landin.Server.Analysis.Request :=
                 Landin.Server.Documents.Request_For (Store, URI);
            begin
               Asked.Options := Options;
               Asked.Firmware_Entry := Firmware_Entry;
               if On_Analysis /= null then
                  On_Analysis.all;
               end if;
               Landin.Server.Analysis.Analyse
                 (Facts, Level, Store.Held, Asked, Item.Context, Item.Answer,
                  Cache => Parse_Cache);
            end;
            Cached.Entries.Insert (Key, Item);
            New_Entry := False;
         end if;
         Visit (Item.Context.all, Item.Answer);
      exception
         when others =>
            if New_Entry then
               Drop (Item);
            else
               Remove (Cached, Key);
            end if;
            raise;
      end With_Analysis;

      --  The host's proof that two spellings name one existing object, as
      --  a token, or "" where it has none.
      function Identity_Token (Path : String) return String;

      function Identity_Token (Path : String) return String is
         Found : constant Landin.Platform.File_Identity :=
           Host.Existing_Identity (Path);
      begin
         return (if Found.Valid
                 then "i" & Found.Device'Image & Found.Inode'Image
                 else "");
      end Identity_Token;

      --  What a report that listed Directory rests on: the directory as it
      --  was spelled, and as the object the host has there.
      procedure Watch_Directory
        (Into : in out String_Sets.Set; Directory : String);

      procedure Watch_Directory
        (Into : in out String_Sets.Set; Directory : String)
      is
         Object : constant String := Identity_Token (Directory);
      begin
         if Directory /= "" then
            Into.Include ("d" & Directory);
            if Object /= "" then
               Into.Include (Object);
            end if;
         end if;
      end Watch_Directory;

      --  What a report that read the source at Path rests on: the path
      --  and the file there, and its module's directory, since a module is
      --  its directory's sources.  With no roots, an entry source is
      --  analysed alone; its siblings do not belong to that compilation.
      procedure Watch_Path
        (Into : in out String_Sets.Set; Key, Path : String);

      procedure Watch_Path
        (Into : in out String_Sets.Set; Key, Path : String)
      is
         Object : constant String := Identity_Token (Path);
      begin
         Into.Include ("p" & Path);
         if Object /= "" then
            Into.Include (Object);
         end if;
         if Path /= Key then
            Watch_Directory (Into, Directory_Of (Path));
         end if;
      end Watch_Path;

      --  Publish every source of the module of URI, and add what was
      --  published and read to Into.
      procedure Publish
        (URI   : String;
         Cache : access Landin.Stages.Syntax.Parse_Cache;
         Shared : Boolean;
         Into  : in out Round);

      procedure Publish
        (URI   : String;
         Cache : access Landin.Stages.Syntax.Parse_Cache;
         Shared : Boolean;
         Into  : in out Round) is
         Key : constant String :=
           Landin.Server.Documents.Module_Key (Store, URI);
         Before : constant String_Sets.Set := Members (Told, Key);

         --  The text a defect was met in: each open document of the
         --  module and its version.  A defect is said once for it.
         function Module_Text return String;

         function Module_Text return String is
            Text : Unbounded.Unbounded_String;
         begin
            for Held of Store.Open loop
               if Landin.Server.Documents.Module_Key
                    (Store, Unbounded.To_String (Held.URI)) = Key
               then
                  Unbounded.Append (Text, " ");
                  Unbounded.Append (Text, Held.URI);
                  Unbounded.Append (Text, Held.Version'Image);
               end if;
            end loop;
            return Unbounded.To_String (Text);
         end Module_Text;

         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result);

         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result)
         is
            Buckets : array (1 .. Landin.Stages.Source_Count (Context)) of
              Landin.Server.Answers.Diagnostic_Indexes.Vector;
            By_Path : Path_Maps.Map;
         begin
            --  The URI map iterates in key order.  Its first document at a
            --  path is the one URI_For would select.
            for Held of Store.Open loop
               declare
                  Path : constant String := Unbounded.To_String (Held.Path);
               begin
                  if not By_Path.Contains (Path) then
                     By_Path.Insert (Path, Held);
                  end if;
               end;
            end loop;

            By_Path.Include
              (Landin.Server.Documents.Held_Path (Store, URI),
               Store.Open.Element (URI));

            --  Dispatch each report item once.  Source identities are the
            --  one-based positions in the compilation's source set.
            for Index in 1 .. Answer.Found.Count loop
               declare
                  Item : constant Diag.Diagnostic := Answer.Found.Get (Index);
                  Source : constant Landin.Source.Source_Id :=
                    Diag.Source_Of (Diag.Primary (Item));
               begin
                  if Source = Landin.Source.No_Source then
                     --  Shown when the module's report first holds it, not
                     --  again at every publication while it still does.
                     declare
                        Kind : constant Positive :=
                          (if Diag.Level (Item) = Diag.Error then 1 else 2);
                        Text : constant String :=
                          Diag.Code (Item) & ": "
                          & Diag.Message (Diag.Primary (Item));
                        Mark : constant String := Kind'Image & Text;
                     begin
                        if not Before.Contains (Mark)
                          and then not Into.Told.Contains (Mark)
                        then
                           Tell (Kind, Text);
                        end if;
                        Into.Told.Include (Mark);
                     end;
                  elsif Source <= Landin.Source.Source_Id (Buckets'Last) then
                     Buckets (Positive (Source)).Append (Index);
                  end if;
               end;
            end loop;

            for Index in 1 .. Landin.Stages.Source_Count (Context) loop
               declare
                  Id   : constant Landin.Source.Source_Id :=
                    Landin.Stages.Nth_Source (Context, Index);
                  Snap : Landin.Source.Snapshot renames
                    Landin.Stages.Source (Context, Id).Element.all;
                  Path : constant String := Landin.Source.Name (Snap);
                  --  D1069: the document whose file this source is, however
                  --  the loader spelled its path.
                  Position : constant Path_Maps.Cursor :=
                    By_Path.Find (Store.Held.Held_As (Path));
                  URI : constant String :=
                    (if Path_Maps.Has_Element (Position)
                     then Unbounded.To_String
                       (Path_Maps.Element (Position).URI)
                     else Landin.Server.Documents.URI_Of (Path));
                  Version : constant Long_Long_Integer :=
                    (if Path_Maps.Has_Element (Position)
                     then Path_Maps.Element (Position).Version else -1);
                  Modules : constant not null access Landin.Modules.Table :=
                    Landin.Stages.Modules (Context);
                  --  A module the loader added and no import names is not
                  --  the analysed module's; it is published only to report
                  --  something wrong in it (D543's reference description).
                  Implicit : constant Boolean :=
                    Natural (Id) <= Landin.Modules.Source_Count (Modules.all)
                    and then Landin.Modules.Is_Implicit
                      (Modules.all,
                       Landin.Modules.Module_Of (Modules.all, Id))
                    and then Buckets (Positive (Id)).Is_Empty;
               begin
                  Watch_Path (Into.Watched, Key, Path);
                  if not Implicit then
                     Into.Paths.Include (Path);
                     Send (Landin.Server.Answers.Diagnostics
                       (URI      => URI,
                        Version  => Version,
                        Found    => Answer.Found,
                        Indexes  => Buckets (Positive (Id)),
                        Sources  => Landin.Stages.Sources (Context),
                        Store    => Store,
                        Unit     => Unit));
                  end if;
               end;
            end loop;

            for Directory of Answer.Missing_Directories loop
               Watch_Directory (Into.Watched, Directory);
            end loop;
            for Directory of Answer.Listed_Directories loop
               Watch_Directory (Into.Watched, Directory);
            end loop;

            --  D1068: said once in a session for each option, and to the
            --  editor's log: the setting is the whole workspace's, and a
            --  module that does not declare it is the usual case.
            for Name of Answer.Unused_Options loop
               if not Said_Unused.Contains (Name) then
                  Said_Unused.Include (Name);
                  Tell (2, "refine: the build option `" & Name
                           & "` is not declared by the module of " & URI
                           & " and is not applied to it; a module that"
                           & " declares it is checked with it",
                        Shown => False);
               end if;
            end loop;
         end Visit;
      begin
         if Shared then
            if Statistics /= null then
               Statistics.Cached_Publications :=
                 Statistics.Cached_Publications + 1;
            end if;
            With_Analysis (URI, Visit'Access, Cache);
         else
            if Statistics /= null then
               Statistics.Uncached_Publications :=
                 Statistics.Uncached_Publications + 1;
            end if;
            With_Analysis (URI, Visit'Access);
         end if;
      exception
         --  A defect of this document's analysis, an analysis that
         --  exhausted the stack or the memory among them (D1220): the
         --  unwinding has given back what it took, and the session goes
         --  on.  It is said once for the text that met it, as a report
         --  with no place is, and not at every publication of that text.
         when Error : others =>
            Into.Complete := False;
            declare
               Text : constant String :=
                 "refine: internal compiler defect analysing " & URI
                 & Exhaustion (Error);
               Mark : constant String :=
                 Positive'Image (1) & Text & Module_Text;
            begin
               Channel.Log ("refine lsp: internal compiler defect analysing "
                            & URI & ": "
                            & Ada.Exceptions.Exception_Message (Error));
               if not Before.Contains (Mark)
                 and then not Into.Told.Contains (Mark)
               then
                  Tell (1, Text);
               end if;
               Into.Told.Include (Mark);
            end;
      end Publish;

      --  Replace what the module of Key last reported with what its round
      --  found.  This is done once for a module, after each of its
      --  documents has published: one of two documents at a path may read
      --  a source the other does not, and a path dropped after the first
      --  and restored by the second would make every other reporter of it
      --  stale, and those this one, without end.
      procedure Settle (Key : String; Found : Round);

      procedure Settle (Key : String; Found : Round) is
         Was       : constant String_Sets.Set := Members (Published, Key);
         Was_Watch : constant String_Sets.Set := Members (Watched, Key);
         Now       : String_Sets.Set := Found.Paths;
         Now_Watch : String_Sets.Set := Found.Watched;
         Now_Told  : String_Sets.Set := Found.Told;
      begin
         if not Found.Complete then
            Now.Union (Was);
            Now_Watch.Union (Was_Watch);
            Now_Told.Union (Members (Told, Key));
         end if;
         --  A path last published to and not reported on now is clear.
         for Path of Was loop
            if not Now.Contains (Path) then
               Clear_Unless_Shared (Key, Path);
               Remove (Path_Users, Path, Key);
            end if;
         end loop;
         for Path of Now loop
            if not Was.Contains (Path) then
               Add (Path_Users, Path, Key);
            end if;
         end loop;
         for Token of Was_Watch loop
            if not Now_Watch.Contains (Token) then
               Remove (Watchers, Token, Key);
            end if;
         end loop;
         for Token of Now_Watch loop
            if not Was_Watch.Contains (Token) then
               Add (Watchers, Token, Key);
            end if;
         end loop;
         Published.Include (Key, Now);
         Watched.Include (Key, Now_Watch);
         Told.Include (Key, Now_Told);
      end Settle;

      --  Forget what the module of Key reported, clearing what it alone
      --  published.  Closing names the document being closed and Closed
      --  the published paths that were its file.
      procedure Forget
        (Key, Closing : String; Closed : String_Sets.Set);

      procedure Forget
        (Key, Closing : String; Closed : String_Sets.Set)
      is
         Cleared_URI : Boolean := False;
      begin
         for Path of Members (Published, Key) loop
            if Closed.Contains (Path) then
               if not Cleared_URI then
                  Send (Landin.Server.Answers.Cleared (Closing));
                  Cleared_URI := True;
               end if;
            else
               Clear_Unless_Shared (Key, Path);
            end if;
            Remove (Path_Users, Path, Key);
         end loop;
         if not Cleared_URI then
            Send (Landin.Server.Answers.Cleared (Closing));
         end if;
         for Token of Members (Watched, Key) loop
            Remove (Watchers, Token, Key);
         end loop;
         Published.Exclude (Key);
         Watched.Exclude (Key);
         Told.Exclude (Key);
      end Forget;

      --  Publish every stale module, each through one of its documents.
      procedure Publish_Stale;

      procedure Publish_Stale is
         Cache : aliased Landin.Stages.Syntax.Parse_Cache;
         Seen : String_Sets.Set;
         Shared : String_Sets.Set;
      begin
         if Stale.Is_Empty then
            if Statistics /= null then
               Statistics.Empty_Rounds := Statistics.Empty_Rounds + 1;
            end if;
            return;
         end if;
         Landin.Server.Documents.Flush (Store);
         if Natural (Stale.Length) > 1 then
            --  The last publications identify paths that can occur in
            --  more than one of the pending modules.  Unique sources need
            --  no copy, and one pending module needs no cache at all.
            for Key of Stale loop
               for Path of Members (Published, Key) loop
                  if Seen.Contains (Path) then
                     Shared.Include (Path);
                  else
                     Seen.Include (Path);
                  end if;
               end loop;
            end loop;
         end if;
         --  URI aliases can project different bytes while a round is being
         --  published. Keep those paths out of its held-byte snapshot.
         Seen.Clear;
         for Opened of Store.Open loop
            declare
               Path : constant String := Unbounded.To_String (Opened.Path);
            begin
               if Seen.Contains (Path) then
                  Shared.Exclude (Path);
               else
                  Seen.Include (Path);
               end if;
            end;
         end loop;
         if not Shared.Is_Empty then
            for Path of Shared loop
               Landin.Stages.Syntax.Limit_To (Cache, Path);
            end loop;
            for Opened of Store.Open loop
               declare
                  Path : constant String :=
                    Unbounded.To_String (Opened.Path);
               begin
                  if Shared.Contains (Path) then
                     declare
                        Content : Unbounded.Unbounded_String;
                        Status : Landin.Platform.Read_Status;
                     begin
                        if Statistics /= null then
                           Statistics.Held_Snapshots :=
                             Statistics.Held_Snapshots + 1;
                        end if;
                        Store.Held.Read_File (Path, Content, Status);
                        if Status = Landin.Platform.Read_Ok then
                           Landin.Stages.Syntax.Hold
                             (Cache, Path, Unbounded.To_String (Content));
                        end if;
                     end;
                  end if;
               end;
            end loop;
         end if;
         while not Stale.Is_Empty loop
            declare
               Key : constant String := Stale.First_Element;
               Has_Alias : Boolean := False;
               Paths : String_Sets.Set;
               Found : Round;
               Any   : Boolean := False;
            begin
               Stale.Delete_First;
               Remove (Cached, Key);
               for Held of Store.Open loop
                  if Landin.Server.Documents.Module_Key
                       (Store, Unbounded.To_String (Held.URI)) = Key
                  then
                     if Paths.Contains (Unbounded.To_String (Held.Path)) then
                        Has_Alias := True;
                        exit;
                     end if;
                     Paths.Include (Unbounded.To_String (Held.Path));
                  end if;
               end loop;
               for Held of Store.Open loop
                  if Landin.Server.Documents.Module_Key
                       (Store, Unbounded.To_String (Held.URI)) = Key
                  then
                     Publish
                       (Unbounded.To_String (Held.URI), Cache'Access,
                        not Shared.Is_Empty, Found);
                     Any := True;
                     exit when not Has_Alias;
                  end if;
               end loop;
               if Any then
                  Settle (Key, Found);
               end if;
            end;
         end loop;
         if Statistics /= null then
            Statistics.Reused_Parses := Statistics.Reused_Parses
              + Landin.Stages.Syntax.Reuse_Count (Cache);
         end if;
      end Publish_Stale;

      procedure Mark_Stale_Path (Path : String);
      procedure Mark_Stale (URI : String);

      procedure Mark_Stale_Path (Path : String) is
         Directory : constant String := Directory_Of (Path);

         procedure Mark (Token : String);
         procedure Mark_Beneath (Prefix : String);

         procedure Mark (Token : String) is
         begin
            if Token /= "" then
               Stale.Union (Members (Watchers, Token));
            end if;
         end Mark;

         --  Every watcher of a token that begins with Prefix.
         procedure Mark_Beneath (Prefix : String) is
            Position : Set_Maps.Cursor := Watchers.Ceiling (Prefix);
         begin
            while Set_Maps.Has_Element (Position)
              and then Starts (Set_Maps.Key (Position), Prefix)
            loop
               Stale.Union (Set_Maps.Element (Position));
               Set_Maps.Next (Position);
            end loop;
         end Mark_Beneath;
      begin
         Clear (Cached);
         --  The source itself, by its name and as the file the host has
         --  there, which a report may have read under another spelling.
         Mark ("p" & Path);
         Mark (Identity_Token (Path));
         --  A module is its directory's source inventory.  A newly added
         --  file has no prior path users, but changes every compilation
         --  that listed its directory: one that read another source there,
         --  found it empty, or looked for it and found none, where a newly
         --  created source can satisfy a formerly absent import.
         if Directory /= "" then
            Mark ("d" & Directory);
            Mark (Identity_Token (Directory));
         end if;
         --  A change reported for a directory, removed or renamed with
         --  what it held: itself and everything beneath it.
         Mark ("d" & Path);
         Mark_Beneath ("d" & Path & "/");
         Mark_Beneath ("p" & Path & "/");
         for Held of Store.Open loop
            declare
               Key : constant String := Landin.Server.Documents.Module_Key
                 (Store, Unbounded.To_String (Held.URI));
            begin
               if Key = Directory or else Key = Path then
                  Stale.Include (Key);
               end if;
            end;
         end loop;
      end Mark_Stale_Path;

      procedure Mark_Stale (URI : String) is
         Key : constant String :=
           Landin.Server.Documents.Module_Key (Store, URI);
      begin
         Stale.Include (Key);
         Mark_Stale_Path (Landin.Server.Documents.Held_Path (Store, URI));
      end Mark_Stale;

      ------------------------------------------------------------------
      --  Messages
      ------------------------------------------------------------------

      procedure Initialize (Message : J.Document; Id, Params : J.Value);

      procedure Initialize (Message : J.Document; Id, Params : J.Value) is
         General  : constant J.Value := J.Member
           (Message, J.Member (Message, Params, "capabilities"), "general");
         Watched  : constant J.Value := J.Member
           (Message,
            J.Member
              (Message,
               J.Member
                 (Message, J.Member (Message, Params, "capabilities"),
                  "workspace"),
               "didChangeWatchedFiles"),
            "dynamicRegistration");
         Offered  : constant J.Value :=
           J.Member (Message, General, "positionEncodings");
         Settings : constant J.Value :=
           J.Member (Message, Params, "initializationOptions");
         Folders  : constant J.Value :=
           J.Member (Message, Params, "workspaceFolders");
         Root_URI : constant J.Value := J.Member (Message, Params, "rootUri");
         Bad      : Unbounded.Unbounded_String;

         procedure Add_Error (Description : String);
         procedure Add_Root (URI : String);

         procedure Add_Error (Description : String) is
         begin
            if Unbounded.Length (Bad) > 0 then
               Unbounded.Append (Bad, ASCII.LF);
            end if;
            Unbounded.Append (Bad, Description);
         end Add_Error;

         procedure Add_Root (URI : String) is
            Path : constant String :=
              Landin.Server.Documents.Root_Path_Of (URI);
         begin
            if Path = "" then
               Add_Error ("a root is not a file URI: " & URI);
            else
               Store.Roots.Append (Path);
            end if;
         end Add_Root;
      begin
         if J.Is_Kind (Message, Offered, J.Array_Value) then
            for Position in 1 .. J.Length (Message, Offered) loop
               declare
                  One : constant J.Value :=
                    J.Element (Message, Offered, Position);
               begin
                  if J.Is_Kind (Message, One, J.String_Value)
                    and then J.Text (Message, One) = "utf-8"
                  then
                     Unit := Positions.UTF_8;
                  end if;
               end;
            end loop;
         end if;

         --  Roots: the ones the editor configured, or its workspace
         --  folders in order, or the root it opened.
         declare
            Roots : constant J.Value := J.Member (Message, Settings, "roots");
         begin
            if J.Is_Kind (Message, Roots, J.Array_Value) then
               for Position in 1 .. J.Length (Message, Roots) loop
                  declare
                     One : constant J.Value :=
                       J.Element (Message, Roots, Position);
                  begin
                     if J.Is_Kind (Message, One, J.String_Value) then
                        Add_Root (J.Text (Message, One));
                     else
                        Add_Error ("a root is not a string");
                     end if;
                  end;
               end loop;
            elsif J.Is_Kind (Message, Folders, J.Array_Value) then
               for Position in 1 .. J.Length (Message, Folders) loop
                  declare
                     URI : constant J.Value := J.Member
                       (Message, J.Element (Message, Folders, Position),
                        "uri");
                  begin
                     if J.Is_Kind (Message, URI, J.String_Value) then
                        Add_Root (J.Text (Message, URI));
                     end if;
                  end;
               end loop;
            elsif J.Is_Kind (Message, Root_URI, J.String_Value) then
               Add_Root (J.Text (Message, Root_URI));
            end if;
         end;

         --  The library beside this compiler follows them, found as
         --  `refine` finds it.
         Store.Library := Unbounded.To_Unbounded_String
           (Landin.Driver.Library.Located (Host.all));

         declare
            Target : constant J.Value :=
              J.Member (Message, Settings, "target");
         begin
            if J.Is_Kind (Message, Target, J.String_Value) then
               declare
                  Name : constant String := J.Text (Message, Target);
               begin
                  if Landin.Targets.Selection.Is_Described (Name) then
                     Facts := Landin.Targets.Selection.Described (Name);
                  else
                     Add_Error ("unknown target: " & Name);
                  end if;
               end;
            elsif J.Is_Present (Target) then
               Add_Error ("a target is a string");
            elsif not Has_Default then
               Add_Error
                 ("no target describes this compiler's host, "
                  & Landin.Targets.Selection.Build_Triplet
                  & "; name one with the target option");
            end if;
            Level := Landin.Targets.Levels.Default_Level (Facts);
         end;

         --  After the target, because a level belongs to its family; the
         --  driver resolves `--level=` in the same order.
         declare
            Named : constant J.Value :=
              J.Member (Message, Settings, "level");
         begin
            if J.Is_Kind (Message, Named, J.String_Value) then
               declare
                  Name : constant String := J.Text (Message, Named);
               begin
                  if Landin.Targets.Levels.Is_Level_Of (Facts, Name) then
                     Level := Landin.Targets.Levels.Level_Named (Facts, Name);
                  else
                     Add_Error
                       ("error[L0009]: unknown level for "
                        & Landin.Targets.Name (Facts)
                        & ": " & Name);
                  end if;
               end;
            elsif J.Is_Present (Named) then
               Add_Error ("a level is a string");
            end if;
         end;

         declare
            Given : constant J.Value :=
              J.Member (Message, Settings, "options");
         begin
            if J.Is_Kind (Message, Given, J.Object_Value) then
               for Position in 1 .. J.Length (Message, Given) loop
                  declare
                     Name  : constant String :=
                       J.Key (Message, Given, Position);
                     Value : constant J.Value :=
                       J.Member_Value (Message, Given, Position);
                  begin
                     if not Landin.Configuration.Is_Option_Name (Name)
                       or else not J.Is_Kind (Message, Value, J.String_Value)
                       or else J.Text (Message, Value) = ""
                     then
                        Add_Error ("invalid build option: " & Name);
                     else
                        Options.Append
                          (Name & "=" & J.Text (Message, Value));
                     end if;
                  end;
               end loop;
            elsif J.Is_Present (Given) then
               Add_Error ("options are an object");
            end if;
         end;

         declare
            Named : constant J.Value :=
              J.Member (Message, Settings, "firmwareEntry");
         begin
            if J.Is_Kind (Message, Named, J.String_Value) then
               if J.Text (Message, Named) = "" then
                  Add_Error ("firmwareEntry is empty");
               elsif not Landin.Targets.Is_Firmware (Facts) then
                  Add_Error ("firmwareEntry requires a firmware target;"
                             & " see refine targets");
               else
                  Firmware_Entry :=
                    Unbounded.To_Unbounded_String (J.Text (Message, Named));
               end if;
            elsif J.Is_Present (Named) then
               Add_Error ("firmwareEntry is a string");
            end if;
         end;

         Respond (Id_Text (Message, Id), Landin.Server.Answers.Capabilities
           (Unit));
         Started := True;
         Watch_Registration_Offered :=
           J.Is_Kind (Message, Watched, J.True_Value);
         if Unbounded.Length (Bad) > 0 then
            Tell (1, "refine: " & Unbounded.To_String (Bad));
         end if;
      end Initialize;

      --  The text of params.textDocument.uri, or "".
      function Document_URI (Message : J.Document; Params : J.Value)
        return String;

      function Document_URI (Message : J.Document; Params : J.Value)
        return String
      is
         URI : constant J.Value := J.Member
           (Message, J.Member (Message, Params, "textDocument"), "uri");
      begin
         return (if J.Is_Kind (Message, URI, J.String_Value)
                 then J.Text (Message, URI) else "");
      end Document_URI;

      --  Reject malformed coordinates rather than letting a bad edit
      --  silently name the beginning or end of a different line.
      function Read_Position
        (Message : J.Document; Value : J.Value;
         Where : out Positions.Position) return Boolean;

      function Read_Position
        (Message : J.Document; Value : J.Value;
         Where : out Positions.Position) return Boolean
      is
         Line : constant J.Value := J.Member (Message, Value, "line");
         Column : constant J.Value := J.Member (Message, Value, "character");
      begin
         Where := (others => 0);
         if not J.Is_Integer (Message, Line)
           or else not J.Is_Integer (Message, Column)
           or else J.Integer_Of (Message, Line) not in
             0 .. J.Integer_Value (Natural'Last)
           or else J.Integer_Of (Message, Column) not in
             0 .. J.Integer_Value (Natural'Last)
         then
            return False;
         end if;
         Where := (Line => Natural (J.Integer_Of (Message, Line)),
                   Character => Natural (J.Integer_Of (Message, Column)));
         return True;
      end Read_Position;

      --  A change's range, if it has one.  Well_Formed is False for a
      --  change with no text, or a range that is malformed or ends before
      --  it starts.
      procedure Read_Change
        (Message : J.Document; Change : J.Value;
         Well_Formed, Ranged : out Boolean;
         First, Last : out Positions.Position);

      procedure Read_Change
        (Message : J.Document; Change : J.Value;
         Well_Formed, Ranged : out Boolean;
         First, Last : out Positions.Position)
      is
         Text : constant J.Value := J.Member (Message, Change, "text");
         Edit_Range : constant J.Value := J.Member (Message, Change, "range");
      begin
         First := (others => 0);
         Last := (others => 0);
         Ranged := J.Is_Present (Edit_Range);
         Well_Formed := J.Is_Kind (Message, Text, J.String_Value);
         if Well_Formed and then Ranged then
            Well_Formed :=
              J.Is_Kind (Message, Edit_Range, J.Object_Value)
              and then Read_Position
                (Message, J.Member (Message, Edit_Range, "start"), First)
              and then Read_Position
                (Message, J.Member (Message, Edit_Range, "end"), Last)
              and then Landin.Server.Texts.In_Order (First, Last);
         end if;
      end Read_Change;

      --  Apply the changes in notification order.  A range is measured in
      --  the text left by the preceding change, in the negotiated unit.
      --  Every change is read before any is applied, and an in-order range
      --  always applies, so a refused notification changes nothing and no
      --  text has to be kept to undo one.
      function Change_Document
        (Message : J.Document; Changes : J.Value; URI : String;
         Version : Long_Long_Integer) return Boolean;

      function Change_Document
        (Message : J.Document; Changes : J.Value; URI : String;
         Version : Long_Long_Integer) return Boolean
      is
         Well_Formed, Ranged : Boolean;
         First, Last : Positions.Position;
      begin
         for Index in 1 .. J.Length (Message, Changes) loop
            Read_Change
              (Message, J.Element (Message, Changes, Index),
               Well_Formed, Ranged, First, Last);
            if not Well_Formed then
               return False;
            end if;
         end loop;
         for Index in 1 .. J.Length (Message, Changes) loop
            declare
               Change : constant J.Value :=
                 J.Element (Message, Changes, Index);
               Text : constant String :=
                 J.Text (Message, J.Member (Message, Change, "text"));
            begin
               Read_Change
                 (Message, Change, Well_Formed, Ranged, First, Last);
               if Ranged then
                  Landin.Server.Documents.Edit
                    (Store, URI, First, Last, Unit, Text);
               else
                  Landin.Server.Documents.Change (Store, URI, Text);
               end if;
            end;
         end loop;
         Landin.Server.Documents.Set_Version (Store, URI, Version);
         return True;
      end Change_Document;

      procedure Notification
        (Message : J.Document; Method : String; Params : J.Value);

      procedure Notification
        (Message : J.Document; Method : String; Params : J.Value)
      is
         Item : constant J.Value :=
           J.Member (Message, Params, "textDocument");
         URI  : constant String := Document_URI (Message, Params);
         Version : constant J.Value := J.Member (Message, Item, "version");
         Version_Number : constant Long_Long_Integer :=
           (if J.Is_Integer (Message, Version)
            then Long_Long_Integer (J.Integer_Of (Message, Version))
            else 0);
      begin
         if Method = "exit" then
            null;
         elsif not Started then
            null;
         elsif Method = "initialized" then
            if Watch_Registration_Offered then
               Send ("{""jsonrpc"":""2.0"",""id"":""refine-watch"",""method"":"
                     & """client/registerCapability"",""params"":"
                     & "{""registrations"":[{""id"":""refine-ldn-files"","
                     & """method"":""workspace/didChangeWatchedFiles"","
                     & """registerOptions"":"
                     & "{""watchers"":[{""globPattern"":""**/*.ldn""}]}}]}}");
               Watch_Registration_Offered := False;
            end if;
         elsif Method = "textDocument/didOpen" then
            declare
               Text : constant J.Value := J.Member (Message, Item, "text");
            begin
               if URI /= "" and then J.Is_Kind (Message, Text, J.String_Value)
               then
                  Landin.Server.Documents.Open
                    (Store, URI, Version_Number, J.Text (Message, Text));
                  Mark_Stale (URI);
               end if;
            end;
         elsif Method = "textDocument/didChange" then
            declare
               Changes : constant J.Value :=
                 J.Member (Message, Params, "contentChanges");
            begin
               if URI /= ""
                 and then Landin.Server.Documents.Is_Open (Store, URI)
                 and then J.Is_Kind (Message, Changes, J.Array_Value)
                 and then J.Length (Message, Changes) > 0
               then
                  if Change_Document
                    (Message, Changes, URI, Version_Number)
                  then
                     Mark_Stale (URI);
                  end if;
               end if;
            end;
         elsif Method = "workspace/didChangeWatchedFiles" then
            declare
               Changes : constant J.Value :=
                 J.Member (Message, Params, "changes");
            begin
               if J.Is_Kind (Message, Changes, J.Array_Value) then
                  for Index in 1 .. J.Length (Message, Changes) loop
                     declare
                        Changed : constant J.Value :=
                          J.Element (Message, Changes, Index);
                        File_URI : constant J.Value :=
                          J.Member (Message, Changed, "uri");
                     begin
                        if J.Is_Kind (Message, File_URI, J.String_Value) then
                           declare
                              --  A change may name a directory, with or
                              --  without a final slash.
                              Path : constant String :=
                                Landin.Server.Documents.Root_Path_Of
                                  (J.Text (Message, File_URI));
                           begin
                              if Path /= "" then
                                 Mark_Stale_Path (Path);
                              end if;
                           end;
                        end if;
                     end;
                  end loop;
               end if;
            end;
         elsif Method = "textDocument/didClose" then
            if URI /= "" and then Landin.Server.Documents.Is_Open (Store, URI)
            then
               declare
                  Key : constant String :=
                    Landin.Server.Documents.Module_Key (Store, URI);
                  Closing_Path : constant String :=
                    Landin.Server.Documents.Held_Path (Store, URI);
                  Others_Open : Boolean := False;
                  --  The published paths that are this document's file,
                  --  asked while it is still held.
                  Closed : String_Sets.Set;
               begin
                  for Path of Members (Published, Key) loop
                     if Store.Held.Held_As (Path) = Closing_Path then
                        Closed.Include (Path);
                     end if;
                  end loop;
                  Clear (Cached);
                  Landin.Server.Documents.Close (Store, URI);
                  Mark_Stale_Path (Closing_Path);
                  for Held of Store.Open loop
                     if Landin.Server.Documents.Module_Key
                          (Store, Unbounded.To_String (Held.URI)) = Key
                     then
                        Others_Open := True;
                     end if;
                  end loop;
                  if Others_Open then
                     Send (Landin.Server.Answers.Cleared (URI));
                     Stale.Include (Key);
                  else
                     --  Nothing of the module is open: clear what it said.
                     Stale.Exclude (Key);
                     Forget (Key, URI, Closed);
                  end if;
               end;
            end if;
         end if;
      exception
         when Error : others =>
            --  As a request's defect is answered and the session goes on,
            --  so a notification's is said and the session goes on.
            Channel.Log ("refine lsp: internal compiler defect handling "
                         & Method & ": "
                         & Ada.Exceptions.Exception_Message (Error));
            Tell (1, "refine: internal compiler defect handling " & Method
                     & Exhaustion (Error));
      end Notification;

      procedure Request
        (Message : J.Document; Id : J.Value; Method : String;
         Params  : J.Value);

      procedure Request
        (Message : J.Document; Id : J.Value; Method : String;
         Params  : J.Value)
      is
         Answer_Id : constant String := Id_Text (Message, Id);
         URI       : constant String := Document_URI (Message, Params);
      begin
         if Method = "initialize" then
            if Started then
               Refuse (Answer_Id, Invalid_Request, "already initialized");
            else
               Initialize (Message, Id, Params);
            end if;
            return;
         elsif not Started then
            Refuse (Answer_Id, Not_Initialized, "the server is not"
                    & " initialized");
            return;
         elsif Stopping then
            Refuse (Answer_Id, Invalid_Request, "the server is shutting"
                    & " down");
            return;
         elsif Method = "shutdown" then
            --  What was edited is reported before the server stops.
            Publish_Stale;
            Stopping := True;
            Respond (Answer_Id, "null");
            return;
         end if;

         if Method not in "textDocument/formatting" | "textDocument/codeAction"
                        | "textDocument/definition" | "textDocument/hover"
         then
            Refuse (Answer_Id, Method_Not_Found, "unsupported: " & Method);
            return;
         elsif URI = ""
           or else not Landin.Server.Documents.Is_Open (Store, URI)
         then
            Refuse (Answer_Id, Invalid_Params, "the document is not open");
            return;
         end if;

         if Method = "textDocument/formatting" then
            declare
               Path    : constant String :=
                 Landin.Server.Documents.Held_Path (Store, URI);
               Content : Unbounded.Unbounded_String;
               Read    : Landin.Platform.Read_Status;
               Sources : Landin.Source.Sets.Source_Set;
            begin
               Landin.Server.Documents.Flush (Store);
               Activate (URI);
               Store.Held.Read_File (Path, Content, Read);
               declare
                  Text   : constant String := Unbounded.To_String (Content);
                  Laid   : constant Landin.Formatting.Result :=
                    Landin.Formatting.Format (Sources, Path, Text);
               begin
                  Respond (Answer_Id, Landin.Server.Answers.Formatting
                    (Laid, Text, Unit));
               end;
            end;
         else
            --  Semantic queries need the current module analysis. Formatting
            --  uses the held text alone, so it need not wait for this check.
            Publish_Stale;
            declare
               Result : Unbounded.Unbounded_String :=
                 Unbounded.To_Unbounded_String ("null");

               procedure Visit
                 (Context : in out Landin.Stages.Compilation;
                  Answer  : Landin.Server.Analysis.Result);

               procedure Visit
                 (Context : in out Landin.Stages.Compilation;
                  Answer  : Landin.Server.Analysis.Result) is
               begin
                  Result := Unbounded.To_Unbounded_String
                    (Landin.Server.Answers.Query
                       (Method, Message, Params, URI, Context, Answer,
                        Store, Unit));
               end Visit;
            begin
               With_Analysis (URI, Visit'Access);
               Respond (Answer_Id, Unbounded.To_String (Result));
            end;
         end if;
      exception
         when Error : others =>
            Channel.Log ("refine lsp: internal compiler defect answering "
                         & Method & ": "
                         & Ada.Exceptions.Exception_Message (Error));
            Refuse (Answer_Id, Internal_Error,
                    "refine: internal compiler defect" & Exhaustion (Error));
      end Request;

      Outcome : Landin.Server.Transport.Status;
      Body_Of : Unbounded.Unbounded_String;
      Fault   : Unbounded.Unbounded_String;
   begin
      Status := 1;
      if Statistics /= null then
         Statistics.all := (others => 0);
      end if;
      loop
         --  Analysis waits until no more input is ready: a burst of edits
         --  is one analysis, and a request analyses first if it must.
         if not Stale.Is_Empty
           and then not Landin.Server.Transport.Waiting (From, Channel)
         then
            Publish_Stale;
         end if;

         Landin.Server.Transport.Next (From, Channel, Outcome, Body_Of, Fault);
         case Outcome is
            when Landin.Server.Transport.Ended =>
               Channel.Log ("refine lsp: the input ended");
               return;
            when Landin.Server.Transport.Broken =>
               Channel.Log ("refine lsp: " & Unbounded.To_String (Fault));
               return;
            when Landin.Server.Transport.Too_Long =>
               Channel.Log ("refine lsp: a message longer than"
                            & Natural'Image
                                (Landin.Server.Transport.Maximum_Body)
                            & " bytes was skipped");
            when Landin.Server.Transport.Message =>
               declare
                  Message : J.Document;
               begin
                  J.Parse (Message, Unbounded.To_String (Body_Of));
                  if not J.Ok (Message) then
                     Refuse ("null", Parse_Error, J.Fault (Message));
                  elsif not J.Is_Kind
                    (Message, J.Root (Message), J.Object_Value)
                  then
                     Refuse ("null", Invalid_Request, "a message is an"
                             & " object");
                  else
                     declare
                        Root   : constant J.Value := J.Root (Message);
                        Method : constant J.Value :=
                          J.Member (Message, Root, "method");
                        Id     : constant J.Value :=
                          J.Member (Message, Root, "id");
                        Params : constant J.Value :=
                          J.Member (Message, Root, "params");
                        Version : constant J.Value :=
                          J.Member (Message, Root, "jsonrpc");
                     begin
                        if not J.Is_Kind (Message, Version, J.String_Value)
                          or else J.Text (Message, Version) /= "2.0"
                          or else (J.Is_Present (Id)
                                   and then not J.Is_Kind
                                     (Message, Id, J.String_Value)
                                   and then not J.Is_Integer (Message, Id))
                        then
                           Refuse ((if J.Is_Present (Id)
                                    and then (J.Is_Kind
                                      (Message, Id, J.String_Value)
                                      or else J.Is_Integer (Message, Id))
                                    then Id_Text (Message, Id) else "null"),
                                   Invalid_Request,
                                   "not a JSON-RPC 2.0 message");
                        elsif not J.Is_Kind
                          (Message, Method, J.String_Value)
                        then
                           --  A response to nothing the server asked.
                           if not J.Is_Present (Id) then
                              Refuse ("null", Invalid_Request,
                                      "a message has no method");
                           end if;
                        elsif J.Is_Present (Id) then
                           Request
                             (Message, Id, J.Text (Message, Method), Params);
                        else
                           Notification
                             (Message, J.Text (Message, Method), Params);
                           if J.Text (Message, Method) = "exit" then
                              Status := (if Stopping then 0 else 1);
                              return;
                           end if;
                        end if;
                     end;
                  end if;
               end;
         end case;
      end loop;
   end Serve;

end Landin.Server.Sessions;
