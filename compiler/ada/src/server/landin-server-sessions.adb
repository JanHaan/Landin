with Ada.Containers.Indefinite_Ordered_Maps;
with Ada.Containers.Indefinite_Ordered_Sets;
with Ada.Finalization;
with Ada.Exceptions;
with Ada.Strings.Unbounded;
with Ada.Unchecked_Deallocation;

with Landin.Configuration;
with Landin.Diagnostics;
with Landin.Formatting;
with Landin.Json;
with Landin.Server.Analysis;
with Landin.Server.Answers;
with Landin.Server.Documents;
with Landin.Server.Positions;
with Landin.Server.Transport;
with Landin.Source;
with Landin.Source.Sets;
with Landin.Stages;
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

   --  JSON-RPC's and the protocol's error codes.
   Parse_Error          : constant := -32700;
   Invalid_Request      : constant := -32600;
   Method_Not_Found     : constant := -32601;
   Invalid_Params       : constant := -32602;
   Internal_Error       : constant := -32603;
   Not_Initialized      : constant := -32002;

   package String_Sets is new Ada.Containers.Indefinite_Ordered_Sets
     (Element_Type => String);

   package Text_Maps is new Ada.Containers.Indefinite_Ordered_Maps
     (Key_Type => String, Element_Type => String);

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

   procedure Serve
     (Channel : in out Landin.Platform.Channel'Class;
      Host    : not null access constant Landin.Platform.Filesystem'Class;
      Status  : out Exit_Status;
      On_Analysis : access procedure := null)
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
      Started   : Boolean := False;
      Stopping  : Boolean := False;
      --  Modules whose documents changed since they were last published.
      Stale     : String_Sets.Set;
      --  Every path each module's last report published to, so a path it
      --  no longer reports on is cleared.
      Published : Text_Maps.Map;
      --  Candidate directories of imports missing at the last report.
      Missing   : Text_Maps.Map;
      Cached    : Analysis_Cache;

      procedure Send (Item : String);

      procedure Send (Item : String) is
      begin
         Channel.Write (Landin.Server.Transport.Framed (Item));
      end Send;

      --  A publication belongs to a path, even when several open entry
      --  modules read it.  Refresh another reporter instead of erasing its
      --  diagnostics when one module stops reporting that path.
      procedure Clear_Unless_Shared
        (Key, Path : String; Closing_URI : String := "");

      procedure Clear_Unless_Shared
        (Key, Path : String; Closing_URI : String := "")
      is
         Shared : Boolean := False;
      begin
         for Position in Published.Iterate loop
            if Text_Maps.Key (Position) /= Key
              and then Unbounded.Index
                (Unbounded.To_Unbounded_String
                   (ASCII.LF & Text_Maps.Element (Position)),
                 ASCII.LF & Path & ASCII.LF) > 0
            then
               Shared := True;
               Stale.Include (Text_Maps.Key (Position));
            end if;
         end loop;
         if not Shared then
            Send (Landin.Server.Answers.Cleared
              (if Closing_URI /= "" then Closing_URI
               else Landin.Server.Documents.URI_For (Store, Path)));
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

      procedure Respond (Id : String; Result : String) is
      begin
         Send ("{""jsonrpc"":""2.0"",""id"":" & Id & ",""result"":"
               & Result & "}");
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

      --  window/showMessage, for what belongs to no document.
      procedure Tell (Kind : Positive; Message : String);

      procedure Tell (Kind : Positive; Message : String) is
         Written : J.Builder;
      begin
         J.Begin_Object (Written);
         J.Name (Written, "jsonrpc");
         J.Write_String (Written, "2.0");
         J.Name (Written, "method");
         J.Write_String (Written, "window/showMessage");
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

      --  Keep checked modules until a document changes or closes.
      procedure With_Analysis
        (URI   : String;
         Visit : not null access procedure
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result));

      procedure With_Analysis
        (URI   : String;
         Visit : not null access procedure
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result))
      is
         Key : constant String :=
           Landin.Server.Documents.Module_Key (Store, URI);
         Item : Analysis_Access;
         New_Entry : Boolean := False;
      begin
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
               if On_Analysis /= null then
                  On_Analysis.all;
               end if;
               Landin.Server.Analysis.Analyse
                 (Facts, Level, Store.Held, Asked, Item.Context, Item.Answer);
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

      --  Publish every source of the module of URI.
      procedure Publish (URI : String);

      procedure Publish (URI : String) is
         Key : constant String :=
           Landin.Server.Documents.Module_Key (Store, URI);

         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result);

         procedure Visit
           (Context : in out Landin.Stages.Compilation;
            Answer  : Landin.Server.Analysis.Result)
         is
            Now     : String_Sets.Set;
            Was     : String_Sets.Set;
            Buckets : array (1 .. Landin.Stages.Source_Count (Context)) of
              Landin.Server.Answers.Diagnostic_Indexes.Vector;
         begin
            if Published.Contains (Key) then
               declare
                  Earlier : constant String := Published.Element (Key);
                  First   : Positive := Earlier'First;
               begin
                  for Index in Earlier'Range loop
                     if Earlier (Index) = ASCII.LF then
                        Was.Include (Earlier (First .. Index - 1));
                        First := Index + 1;
                     end if;
                  end loop;
               end;
            end if;

            --  Dispatch each report item once.  Source identities are the
            --  one-based positions in the compilation's source set.
            for Index in 1 .. Answer.Found.Count loop
               declare
                  Item : constant Diag.Diagnostic := Answer.Found.Get (Index);
                  Source : constant Landin.Source.Source_Id :=
                    Diag.Source_Of (Diag.Primary (Item));
               begin
                  if Source = Landin.Source.No_Source then
                     Tell ((if Diag.Level (Item) = Diag.Error then 1 else 2),
                           Diag.Code (Item) & ": "
                           & Diag.Message (Diag.Primary (Item)));
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
               begin
                  Now.Include (Path);
                  Send (Landin.Server.Answers.Diagnostics
                    (URI      => Landin.Server.Documents.URI_For (Store, Path),
                     Version  => Landin.Server.Answers.Version_Of
                       (Store, Path),
                     Found    => Answer.Found,
                     Indexes  => Buckets (Positive (Id)),
                     Sources  => Landin.Stages.Sources (Context),
                     Store    => Store,
                     Unit     => Unit));
               end;
            end loop;

            --  A path last published to and not reported on now is clear.
            for Path of Was loop
               if not Now.Contains (Path) then
                  Clear_Unless_Shared (Key, Path);
               end if;
            end loop;
            declare
               Kept : Unbounded.Unbounded_String;
               Absent : Unbounded.Unbounded_String;
            begin
               for Path of Now loop
                  Unbounded.Append (Kept, Path & ASCII.LF);
               end loop;
               for Path of Answer.Missing_Directories loop
                  Unbounded.Append (Absent, Path & ASCII.LF);
               end loop;
               Published.Include (Key, Unbounded.To_String (Kept));
               Missing.Include (Key, Unbounded.To_String (Absent));
            end;
         end Visit;
      begin
         With_Analysis (URI, Visit'Access);
      exception
         when Storage_Error =>
            raise;
         when Error : others =>
            Channel.Log ("refine lsp: internal compiler defect analysing "
                         & URI & ": "
                         & Ada.Exceptions.Exception_Message (Error));
            Tell (1, "refine: internal compiler defect analysing " & URI);
      end Publish;

      --  Publish every stale module, each through one of its documents.
      procedure Publish_Stale;

      procedure Publish_Stale is
      begin
         while not Stale.Is_Empty loop
            declare
               Key : constant String := Stale.First_Element;
            begin
               Stale.Delete_First;
               Remove (Cached, Key);
               for Held of Store.Open loop
                  if Landin.Server.Documents.Module_Key
                       (Store, Unbounded.To_String (Held.URI)) = Key
                  then
                     Publish (Unbounded.To_String (Held.URI));
                     exit;
                  end if;
               end loop;
            end;
         end loop;
      end Publish_Stale;

      procedure Mark_Stale (URI : String);

      procedure Mark_Stale (URI : String) is
         Key : constant String :=
           Landin.Server.Documents.Module_Key (Store, URI);
         Path : constant String :=
           Landin.Server.Documents.Held_Path (Store, URI);
      begin
         Clear (Cached);
         Stale.Include (Key);
         --  A change to a file another module imports makes that module
         --  stale too: every open module that reported on this path.
         for Position in Published.Iterate loop
            if Unbounded.Index
                 (Unbounded.To_Unbounded_String
                    (ASCII.LF & Text_Maps.Element (Position)),
                  ASCII.LF
                  & Path
                  & ASCII.LF) > 0
            then
               Stale.Include (Text_Maps.Key (Position));
            end if;
         end loop;
         --  A source opened in a formerly absent import directory makes
         --  that import available even though no source was published there.
         for Position in Missing.Iterate loop
            if Unbounded.Index
                 (Unbounded.To_Unbounded_String
                    (ASCII.LF & Text_Maps.Element (Position)),
                  ASCII.LF & Key & ASCII.LF) > 0
            then
               Stale.Include (Text_Maps.Key (Position));
            end if;
         end loop;
      end Mark_Stale;

      ------------------------------------------------------------------
      --  Messages
      ------------------------------------------------------------------

      procedure Initialize (Message : J.Document; Id, Params : J.Value);

      procedure Initialize (Message : J.Document; Id, Params : J.Value) is
         General  : constant J.Value := J.Member
           (Message, J.Member (Message, Params, "capabilities"), "general");
         Offered  : constant J.Value :=
           J.Member (Message, General, "positionEncodings");
         Settings : constant J.Value :=
           J.Member (Message, Params, "initializationOptions");
         Folders  : constant J.Value :=
           J.Member (Message, Params, "workspaceFolders");
         Root_URI : constant J.Value := J.Member (Message, Params, "rootUri");
         Bad      : Unbounded.Unbounded_String;

         procedure Add_Root (URI : String);

         procedure Add_Root (URI : String) is
            Path : constant String :=
              Landin.Server.Documents.Root_Path_Of (URI);
         begin
            if Path = "" then
               Unbounded.Append (Bad, "a root is not a file URI: " & URI);
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
                        Unbounded.Append (Bad, "a root is not a string");
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
                     Unbounded.Append (Bad, "unknown target: " & Name);
                  end if;
               end;
            elsif J.Is_Present (Target) then
               Unbounded.Append (Bad, "a target is a string");
            elsif not Has_Default then
               Unbounded.Append
                 (Bad, "no target describes this compiler's host, "
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
                     Unbounded.Append
                       (Bad, "unknown level for "
                        & Landin.Targets.Name (Facts) & ": " & Name);
                  end if;
               end;
            elsif J.Is_Present (Named) then
               Unbounded.Append (Bad, "a level is a string");
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
                        Unbounded.Append
                          (Bad, "invalid build option: " & Name);
                     else
                        Options.Append
                          (Name & "=" & J.Text (Message, Value));
                     end if;
                  end;
               end loop;
            elsif J.Is_Present (Given) then
               Unbounded.Append (Bad, "options are an object");
            end if;
         end;

         Respond (Id_Text (Message, Id), Landin.Server.Answers.Capabilities
           (Unit));
         Started := True;
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
                  --  Full synchronisation: the last change is the buffer.
                  declare
                     Text : constant J.Value := J.Member
                       (Message,
                        J.Element (Message, Changes,
                                   J.Length (Message, Changes)),
                        "text");
                  begin
                     if J.Is_Kind (Message, Text, J.String_Value) then
                        Landin.Server.Documents.Change
                          (Store, URI, Version_Number,
                           J.Text (Message, Text));
                        Mark_Stale (URI);
                     end if;
                  end;
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
               begin
                  Clear (Cached);
                  Landin.Server.Documents.Close (Store, URI);
                  for Held of Store.Open loop
                     if Landin.Server.Documents.Module_Key
                          (Store, Unbounded.To_String (Held.URI)) = Key
                     then
                        Others_Open := True;
                     end if;
                  end loop;
                  if Others_Open then
                     Stale.Include (Key);
                  else
                     --  Nothing of the module is open: clear what it said.
                     Stale.Exclude (Key);
                     if Published.Contains (Key) then
                        declare
                           Earlier : constant String :=
                             Published.Element (Key);
                           First   : Positive := Earlier'First;
                        begin
                           for Index in Earlier'Range loop
                              if Earlier (Index) = ASCII.LF then
                                 Clear_Unless_Shared
                                   (Key, Earlier (First .. Index - 1),
                                    (if Earlier (First .. Index - 1)
                                          = Closing_Path
                                     then URI else ""));
                                 First := Index + 1;
                              end if;
                           end loop;
                        end;
                        Published.Delete (Key);
                        Missing.Exclude (Key);
                     else
                        Send (Landin.Server.Answers.Cleared (URI));
                     end if;
                  end if;
               end;
            end if;
         end if;
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

         --  Answer from the documents as they now stand.
         Publish_Stale;

         if Method = "textDocument/formatting" then
            declare
               Path    : constant String :=
                 Landin.Server.Documents.Held_Path (Store, URI);
               Content : Unbounded.Unbounded_String;
               Read    : Landin.Platform.Read_Status;
               Sources : Landin.Source.Sets.Source_Set;
            begin
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
         when Storage_Error =>
            raise;
         when Error : others =>
            Channel.Log ("refine lsp: internal compiler defect answering "
                         & Method & ": "
                         & Ada.Exceptions.Exception_Message (Error));
            Refuse (Answer_Id, Internal_Error,
                    "refine: internal compiler defect");
      end Request;

      Outcome : Landin.Server.Transport.Status;
      Body_Of : Unbounded.Unbounded_String;
      Fault   : Unbounded.Unbounded_String;
   begin
      Status := 1;
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
