with Ada.Exceptions;
with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Build_Identity;
with Landin.Commands.Catalogue;
with Landin.Commands.Presentation;
with Landin.Commands.Response_Files;
with Landin.Commands.Tracing;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Text;
with Landin.Diagnostics.Warning_Policy;
with Landin.Driver.Library;
with Landin.Json;
with Landin.Source;
with Landin.Source.Sets;
with Landin.Targets;
with Landin.Targets.Capabilities;
with Landin.Targets.Levels;

package body Landin.Commands is
   package C renames Catalogue;
   package US renames Ada.Strings.Unbounded;
   package J renames Landin.Json;
   package WP renames Landin.Diagnostics.Warning_Policy;
   use type C.Action;
   use type C.Option;
   use type US.Unbounded_String;
   use type Landin.Targets.Capabilities.Backend_Kind;
   LF : constant Character := ASCII.LF;

   --  Rendering is pure: release status comes from the exact source tag,
   --  independently of the compiler's optimization/build mode.
   function Version_Banner
     (Release_Version, Revision, Source_Digest : String;
      Dirty : Boolean) return String;
   function Version_Banner
     (Release_Version, Revision, Source_Digest : String;
      Dirty : Boolean) return String
   is
      function Short (Text : String) return String is
        (Text (Text'First .. Text'First + Natural'Min (8, Text'Length) - 1));
      Label : constant String :=
        (if Release_Version = "" then "dev" else Release_Version);
      Origin : constant String :=
        (if Revision = "unknown" then "source " & Short (Source_Digest)
         else Short (Revision));
   begin
      if Release_Version /= "" and then not Dirty then
         return "refine " & Label;
      end if;
      return "refine " & Label & " (" & Origin
        & (if Dirty then ", dirty" else "") & ")";
   end Version_Banner;

   function Version_Json (Release_Version : String) return String is
     (if Release_Version = "" then "null" else J.Quoted (Release_Version));

   type Request is record
      Command : C.Action := C.Overview;
      Explicit_Command : Boolean := False;
      Legacy : Boolean := False;
      Legacy_Identity : Boolean := False;
      Wants_Help : Boolean := False;
      Verbosity : Natural := 0;
      Quiet : Boolean := False;
      Color : US.Unbounded_String := US.To_Unbounded_String ("auto");
      Style : Presentation.Style := Presentation.Human;
      Structured : Boolean := False;
      Dry_Run : Boolean := False;
      Depfile : US.Unbounded_String;
      Policy : WP.Policy := WP.Defaults;
      Forwarded : Landin.Platform.Path_List;
      Operands : Landin.Platform.Path_List;
      --  D526: what follows `run`'s `--`, the program's, exactly.
      Program_Arguments : Landin.Platform.Path_List;
      Problem : US.Unbounded_String;
   end record;

   --  D526: what `refine run` names its executable, and what the bare
   --  form's line suggests `-o` names: the entry operand's last name
   --  without `.ldn`.
   function Program_Name (Operand : String) return String;

   function Program_Name (Operand : String) return String is
      First : Positive := Operand'First;
      Last : Natural := Operand'Last;
   begin
      while Last >= Operand'First and then Operand (Last) = '/' loop
         Last := Last - 1;
      end loop;
      for Index in Operand'First .. Last loop
         if Operand (Index) = '/' then
            First := Index + 1;
         end if;
      end loop;
      declare
         Base : constant String := Operand (First .. Last);
      begin
         if Base'Length > 4 and then Base (Base'Last - 3 .. Base'Last) = ".ldn"
         then
            return Base (Base'First .. Base'Last - 4);
         elsif Base = "" or else Base = "." or else Base = ".." then
            return "program";
         end if;
         return Base;
      end;
   end Program_Name;

   function Parse
     (Arguments : Landin.Platform.Path_List;
      Host : Landin.Platform.Filesystem'Class) return Request;

   function Parse
     (Arguments : Landin.Platform.Path_List;
      Host : Landin.Platform.Filesystem'Class) return Request
   is
      Result : Request;
      Expanded : Landin.Platform.Path_List;
      Seen : array (C.Option) of Boolean := [others => False];
      Specific_Before : Boolean := False;
      --  D384: the first command-specific option written before any
      --  command, as it was written, for the refusal to name.
      First_Specific : US.Unbounded_String;
      First_Flag : C.Option := C.Help_Flag;
      Literal : Boolean := False;
      --  How the option given before its command is placed after it.
      function Placed (Command : C.Action) return String;
      function Placed (Command : C.Action) return String is
        (US.To_String (First_Specific) & " is an option of "
         & C.Owners (First_Flag)
         & (if Command = C.Overview
               or else C.Accepts (Command, First_Flag)
            then ""
            else ", not of " & C.Name (Command))
         & ", and follows its command: refine "
         & C.Name
             (if Command /= C.Overview
                and then C.Accepts (Command, First_Flag)
              then Command else C.First_Owner (First_Flag))
         & " " & US.To_String (First_Specific) & " ...");
      Index : Positive := 1;
      procedure Refuse (Message : String);
      procedure Refuse (Message : String) is
      begin
         if US.Length (Result.Problem) = 0 then
            Result.Problem := US.To_Unbounded_String (Message);
         end if;
      end Refuse;
   begin
      Response_Files.Expand (Arguments, Host, Expanded, Result.Problem);
      if US.Length (Result.Problem) /= 0 then
         return Result;
      end if;
      while Index <= Natural (Expanded.Length) loop
         declare
            Written : constant String := Expanded.Element (Index);
            --  D524: `-LDIR`, as a C compiler takes it, is `-L DIR`.
            Text : constant String :=
              (if not Literal and then Written'Length > 2
                 and then Written (Written'First .. Written'First + 1) = "-L"
                 and then Written (Written'First + 2) /= '='
               then "-L=" & Written (Written'First + 2 .. Written'Last)
               else Written);
            Equal : constant Natural := Ada.Strings.Fixed.Index (Text, "=");
            Stem : constant String :=
              (if Equal = 0 then Text else Text (Text'First .. Equal - 1));
            Value : US.Unbounded_String;
         begin
            if not Literal and then Text = "--" then
               Literal := True;
            elsif not Literal and then Text in "--version" | "--identify" then
               if Result.Explicit_Command or else Result.Command /= C.Overview
               then
                  Refuse ("version query conflicts with another command");
               else
                  if Text = "--version" and then Specific_Before then
                     Refuse (Placed (C.Version));
                  end if;
                  Result.Legacy_Identity := Text = "--identify";
                  Result.Command := C.Version;
                  Result.Explicit_Command := True;
               end if;
            elsif not Literal and then Text = "-vv" then
               Result.Verbosity := Result.Verbosity + 2;
            elsif not Literal and then Text'Length > 0
              and then Text (Text'First) = '-'
            then
               if not C.Known_Option (Stem) then
                  Refuse ("unknown option: " & Text);
               else
                  declare
                     Flag : constant C.Option := C.Named_Option (Stem);
                  begin
                     if Seen (Flag) and then not C.Repeatable (Flag) then
                        Refuse ("option may be given once: " & Stem);
                     end if;
                     Seen (Flag) := True;
                     if C.Takes_Value (Flag) then
                        if Equal /= 0 then
                           Value := US.To_Unbounded_String
                             (Text (Equal + 1 .. Text'Last));
                        elsif Index < Natural (Expanded.Length)
                          and then Expanded.Element (Index + 1) /= "--"
                          and then (Expanded.Element (Index + 1)'Length = 0
                            or else Expanded.Element (Index + 1)
                              (Expanded.Element (Index + 1)'First) /= '-')
                        then
                           Index := Index + 1;
                           Value := US.To_Unbounded_String
                             (Expanded.Element (Index));
                        else
                           Refuse ("option needs a value: " & Stem);
                        end if;
                        if not C.Valid_Value (Flag, US.To_String (Value)) then
                           Refuse ("invalid value for " & Stem & ": "
                             & US.To_String (Value));
                        end if;
                     elsif Equal /= 0 then
                        Refuse ("option takes no value: " & Stem);
                     end if;
                     if not C.Shared (Flag) then
                        if not Result.Explicit_Command then
                           if not Specific_Before then
                              First_Flag := Flag;
                              First_Specific := US.To_Unbounded_String
                                (Stem & (if C.Takes_Value (Flag)
                                         then (if Stem = "-o" then " "
                                               else "=")
                                              & US.To_String (Value)
                                         else ""));
                           end if;
                           Specific_Before := True;
                        elsif not Result.Legacy_Identity
                          and then not C.Accepts (Result.Command, Flag)
                        then
                           Refuse (Stem & " is not an option of "
                             & C.Name (Result.Command));
                        end if;
                     end if;
                     if Flag in C.Warnings .. C.Deny
                       and then (not Result.Explicit_Command
                         or else Result.Legacy_Identity)
                     then
                        Refuse (Stem & " requires explicit check or compile");
                     end if;
                     case Flag is
                        when C.Help_Flag => Result.Wants_Help := True;
                        when C.Verbose =>
                           Result.Verbosity := Result.Verbosity + 1;
                        when C.Quiet => Result.Quiet := True;
                        when C.Color => Result.Color := Value;
                        when C.Diagnostics =>
                           Result.Style :=
                             (if US.To_String (Value) = "json"
                              then Presentation.JSON
                              elsif US.To_String (Value) = "short"
                              then Presentation.Short else Presentation.Human);
                        when C.JSON => Result.Structured := True;
                        when C.Dry_Run => Result.Dry_Run := True;
                        when C.Depfile => Result.Depfile := Value;
                        when C.Warnings =>
                           if C.Valid_Value (Flag, US.To_String (Value)) then
                              WP.Set_Base (Result.Policy,
                                (if US.To_String (Value) = "all"
                                 then WP.All_Warnings
                                 elsif US.To_String (Value) = "none"
                                 then WP.No_Warnings else WP.Recommended));
                           end if;
                        when C.Warn | C.Allow | C.Deny =>
                           if WP.Valid_Selector (US.To_String (Value)) then
                              WP.Add (Result.Policy, US.To_String (Value),
                                (case Flag is
                                    when C.Allow => WP.Allow,
                                    when C.Deny => WP.Deny,
                                    when others => WP.Warn));
                           end if;
                        when others =>
                           Result.Forwarded.Append (C.Name (Flag)
                             & (if C.Takes_Value (Flag)
                                then "=" & US.To_String (Value) else ""));
                     end case;
                  end;
               end if;
            elsif not Literal and then not Result.Explicit_Command
              and then Result.Operands.Is_Empty and then C.Known (Text)
            then
               Result.Command := C.Named (Text);
               Result.Explicit_Command := True;
               if Specific_Before then
                  Refuse (Placed (Result.Command));
               end if;
            elsif not Literal and then not Result.Explicit_Command
              and then Result.Operands.Is_Empty and then Text = "build"
            then
               Refuse ("build is reserved for future project orchestration");
            elsif Literal and then Result.Command = C.Run then
               --  D526: after `run`'s `--`, every word is the program's,
               --  an empty one too.
               Result.Program_Arguments.Append (Text);
            else
               if Text = "" then
                  Refuse ("empty operand");
               end if;
               Result.Operands.Append (Text);
            end if;
         end;
         Index := Index + 1;
      end loop;
      if not Result.Explicit_Command
        and then (not Result.Operands.Is_Empty or else Specific_Before)
      then
         Result.Legacy := True;
         Result.Command := C.Check;
         if Seen (C.Emit) then
            Result.Command := C.Compile;
         end if;
         for Flag in C.Option loop
            if Seen (Flag) and then not C.Accepts (Result.Command, Flag)
            then
               --  D384: which command it is an option of, and where it
               --  goes, rather than that it needs one.
               declare
                  Written : constant String :=
                    (if Flag = First_Flag
                       and then US.Length (First_Specific) > 0
                     then US.To_String (First_Specific)
                     else C.Name (Flag));
               begin
                  Refuse (Written & " is an option of "
                    & C.Owners (Flag) & "; name the command first: refine "
                    & C.Name (C.First_Owner (Flag)) & " " & Written
                    & " ...");
               end;
            end if;
         end loop;
      end if;
      if Result.Quiet and then Result.Verbosity /= 0 then
         Refuse ("--quiet and --verbose cannot be combined");
      end if;
      case Result.Command is
         when C.Version | C.Targets | C.Server | C.Overview =>
            if not Result.Operands.Is_Empty then
               Refuse (C.Name (Result.Command) & " takes no operands");
            end if;
         when C.Help | C.Completion =>
            if Natural (Result.Operands.Length) > 1 then
               Refuse (C.Name (Result.Command) & " takes one operand");
            end if;
         when C.Run =>
            if Result.Operands.Is_Empty and then not Result.Wants_Help then
               Refuse ("run needs a source to compile and run: refine run"
                 & " program.ldn");
            end if;
         when others => null;
      end case;
      if Result.Command = C.Server
        and then (Result.Verbosity /= 0 or else Result.Quiet
                  or else Seen (C.Color) or else Seen (C.Diagnostics))
      then
         Refuse
           ("lsp uses protocol diagnostics and takes no presentation options");
      end if;
      return Result;
   end Parse;

   function Is_Server
     (Arguments : Landin.Platform.Path_List;
      Host : Landin.Platform.Filesystem'Class) return Boolean
   is
      Asked : constant Request := Parse (Arguments, Host);
   begin
      return Asked.Command = C.Server and then not Asked.Wants_Help
        and then US.Length (Asked.Problem) = 0;
   end Is_Server;

   function Execute
     (Arguments : Landin.Platform.Path_List;
      Host : Landin.Platform.Filesystem'Class;
      Tools : Landin.Platform.Tool_Runner'Class;
      Meter : Landin.Platform.Resource_Meter'Class;
      Built_For : String := Landin.Targets.Selection.Build_Triplet;
      Terminal_Color : Boolean := False) return Landin.Driver.Outcome
   is
      Asked : constant Request := Parse (Arguments, Host);
      Result : Landin.Driver.Outcome;
      Forwarded : Landin.Platform.Path_List := Asked.Forwarded;
      Transcript : aliased US.Unbounded_String;
      function Effective (Flag : C.Option; Default : String) return String;

      --  A Linux executable links static by default and every
      --  other hosted one through its C library; firmware has neither.
      function Default_Link return String;
      function Effective (Flag : C.Option; Default : String) return String is
         Prefix : constant String := C.Name (Flag) & "=";
      begin
         for Text of Asked.Forwarded loop
            if Text'Length >= Prefix'Length
              and then Text (Text'First .. Text'First + Prefix'Length - 1)
                = Prefix
            then
               return Text (Text'First + Prefix'Length .. Text'Last);
            end if;
         end loop;
         return Default;
      end Effective;

      function Default_Link return String is
         Named : constant String := Effective (C.Target, "");
         package Caps renames Landin.Targets.Capabilities;
         use type Caps.Hosted_System;
      begin
         if Named = "" and then not Landin.Targets.Selection.Has_Host_Default
           (Built_For)
         then
            return "unknown";
         end if;
         declare
            Facts : constant Landin.Targets.Target_Facts :=
              (if Named = ""
               then Landin.Targets.Selection.Host_Default (Built_For)
               else Landin.Targets.Selection.Described (Named));
         begin
            return
              (case Caps.Hosted_System_Of (Facts) is
                  when Caps.Linux => "static",
                  when Caps.No_Hosted_System => "none",
                  when others => "libc");
         end;
      exception
         when others =>
            return "unknown";
      end Default_Link;
      procedure Refuse (Message : String);
      procedure Refuse (Message : String) is
         None : Landin.Source.Sets.Source_Set;
      begin
         Result.Status := Landin.Driver.Status_Misuse;
         Result.Found.Append
           (Landin.Diagnostics.Make
              (Code => Landin.Diagnostics.Catalogue.Code
                 (Landin.Diagnostics.Catalogue.Unknown_Option),
               Level => Landin.Diagnostics.Error,
               Source => Landin.Source.No_Source,
               Where => Landin.Source.Empty_Span, Message => Message));
         Result.Report := US.To_Unbounded_String
           (Landin.Diagnostics.Text.Render (Result.Found, None));
      end Refuse;
      --  D526: the private directory `run` writes the executable into.
      Run_Directory : US.Unbounded_String;

      --  D526: refuse another target, make the directory and name the
      --  executable in it.  Refused, or without a directory, nothing runs.
      procedure Prepare_Run;
      procedure Prepare_Run is
         Named : constant String := Effective (C.Target, "");
         Made : Landin.Platform.Write_Status;
         use type Landin.Platform.Write_Status;
         use type Landin.Targets.Target_Facts;
      begin
         if not Landin.Targets.Selection.Has_Host_Default (Built_For) then
            Refuse ("run runs a program on this compiler's host, "
              & Built_For & ", which no target describes; build one with"
              & " refine compile --target=NAME");
            return;
         elsif Named /= ""
           and then Landin.Targets.Selection.Is_Described (Named)
           and then Landin.Targets.Selection.Described (Named)
             /= Landin.Targets.Selection.Host_Default (Built_For)
         then
            Refuse ("run runs a program on this compiler's own host, and"
              & " not on " & Named & "; build one for " & Named
              & " with refine compile --target=" & Named);
            return;
         end if;
         Host.Make_Private_Directory ("refine-run-", Run_Directory, Made);
         if Made /= Landin.Platform.Write_Ok then
            declare
               None : Landin.Source.Sets.Source_Set;
            begin
               Result.Status := Landin.Driver.Status_Reported;
               Result.Found.Append
                 (Landin.Diagnostics.Make
                    (Code => Landin.Diagnostics.Catalogue.Code
                       (Landin.Diagnostics.Catalogue.Unwritable_Output),
                     Level => Landin.Diagnostics.Error,
                     Source => Landin.Source.No_Source,
                     Where => Landin.Source.Empty_Span,
                     Message => "cannot make a private directory for the"
                       & " program under TMPDIR or /tmp"));
               Result.Report := US.To_Unbounded_String
                 (Landin.Diagnostics.Text.Render (Result.Found, None));
            end;
            Run_Directory := US.Null_Unbounded_String;
            return;
         end if;
         Forwarded.Append ("--emit=exe");
         Forwarded.Append ("-o=" & US.To_String (Run_Directory) & "/"
           & Program_Name (Asked.Operands.First_Element));
      end Prepare_Run;

      --  D526: a compiled program is run once its report is written; on
      --  every other way out its directory goes now.
      procedure Finish_Run;
      procedure Finish_Run is
         Removed : Landin.Platform.Remove_Status;
         use type Landin.Platform.Remove_Status;
      begin
         if Result.Status = Landin.Driver.Status_Success then
            Result.Launch_Program := Run_Directory & "/"
              & Program_Name (Asked.Operands.First_Element);
            Result.Launch_Arguments := Asked.Program_Arguments;
            Result.Launch_Directory := Run_Directory;
         else
            Host.Remove_Tree (US.To_String (Run_Directory), Removed);
            if Removed = Landin.Platform.Not_Removable then
               US.Append (Result.Report, "refine: cannot remove "
                 & US.To_String (Run_Directory) & LF);
            end if;
         end if;
      end Finish_Run;

      procedure Identify;
      procedure Identify is
         B : J.Builder;
         --  Which library a compilation would use, so a person can see
         --  which one is in use without compiling anything.
         Named : constant String := Effective (C.Library, "");
         Library_Root : constant String :=
           (if Named /= "" then Named
            else Landin.Driver.Library.Located (Host));
      begin
         if Named /= ""
           and then not Landin.Driver.Library.Holds_Library (Host, Named)
         then
            Refuse ("--library=" & Named & " holds no core, hosted or"
              & " platform directory; name the directory that holds"
              & " them");
            return;
         end if;
         if Asked.Structured then
            J.Begin_Object (B);
            J.Name (B, "schema");
            J.Write_Integer (B, 1);
            J.Name (B, "compiler");
            J.Write_String (B, "refine");
            J.Name (B, "version");
            J.Write_Raw
              (B, Version_Json (Landin.Build_Identity.Release_Version));
            J.Name (B, "revision");
            J.Write_String (B, Landin.Build_Identity.Revision);
            J.Name (B, "source_digest");
            J.Write_String (B, Landin.Build_Identity.Source_Digest);
            J.Name (B, "dirty");
            J.Write_Boolean (B, Landin.Build_Identity.Dirty);
            J.Name (B, "mode");
            J.Write_String (B, Landin.Build_Identity.Mode);
            J.Name (B, "host_triplet");
            J.Write_String (B, Built_For);
            J.Name (B, "library");
            if Library_Root = "" then
               J.Write_Raw (B, "null");
            else
               J.Write_String (B, Library_Root);
            end if;
            J.End_Object (B);
            Result.Output := US.To_Unbounded_String (J.Result (B) & LF);
         else
            Result.Output := US.To_Unbounded_String
              (Version_Banner
                 (Landin.Build_Identity.Release_Version,
                  Landin.Build_Identity.Revision,
                  Landin.Build_Identity.Source_Digest,
                  Landin.Build_Identity.Dirty) & LF
               & "library: "
               & (if Library_Root = "" then "none" else Library_Root) & LF);
         end if;
      end Identify;
      procedure List_Targets;
      procedure List_Targets is
         B : J.Builder;
      begin
         if Asked.Structured then
            J.Begin_Object (B);
            J.Name (B, "schema");
            J.Write_Integer (B, 1);
            J.Name (B, "targets");
            J.Begin_Array (B);
         end if;
         for Index in 1 .. Landin.Targets.Selection.Described_Count loop
            declare
               Name : constant String :=
                 Landin.Targets.Selection.Described_Name (Index);
            begin
               if Asked.Structured then
                  J.Begin_Object (B);
                  J.Name (B, "name");
                  J.Write_String (B, Name);
                  J.Name (B, "emission");
                  J.Write_Boolean
                    (B, Landin.Targets.Capabilities.Backend_For
                       (Landin.Targets.Selection.Described (Name)) /=
                         Landin.Targets.Capabilities.No_Backend);
                  J.Name (B, "levels");
                  J.Write_String (B, Landin.Targets.Levels.Levels_Of
                    (Landin.Targets.Selection.Described (Name)));
                  J.Name (B, "default_level");
                  J.Write_String (B, Landin.Targets.Levels.Name
                    (Landin.Targets.Levels.Default_Level
                       (Landin.Targets.Selection.Described (Name))));
                  J.End_Object (B);
               else
                  US.Append (Result.Output, Name
                    & (if Name = "synthetic-32"
                       then " (checking only)" else "")
                    & ": " & Landin.Targets.Levels.Levels_Of
                      (Landin.Targets.Selection.Described (Name)) & LF);
               end if;
            end;
         end loop;
         if Asked.Structured then
            J.End_Array (B);
            J.End_Object (B);
            Result.Output := US.To_Unbounded_String (J.Result (B) & LF);
         end if;
      end List_Targets;
   begin
      if US.Length (Asked.Problem) /= 0 then
         Refuse (US.To_String (Asked.Problem));
      elsif Asked.Legacy_Identity then
         Forwarded.Prepend ("--identify");
         Result := Landin.Driver.Execute
           (Forwarded, Host, Tools, Meter, Built_For);
      elsif Asked.Wants_Help then
         Result.Output := US.To_Unbounded_String (C.Usage (Asked.Command));
      elsif Asked.Command = C.Help then
         if Asked.Operands.Is_Empty then
            Result.Output := US.To_Unbounded_String (C.Usage);
         elsif Asked.Operands.Element (1) = "reference" then
            Result.Output := US.To_Unbounded_String (C.Reference);
         elsif C.Known (Asked.Operands.Element (1)) then
            Result.Output := US.To_Unbounded_String
              (C.Usage (C.Named (Asked.Operands.Element (1))));
         else
            Refuse ("unknown command: " & Asked.Operands.Element (1));
         end if;
      else
         case Asked.Command is
            when C.Overview =>
               Result.Output := US.To_Unbounded_String (C.Usage);
            when C.Version => Identify;
            when C.Targets => List_Targets;
            when C.Completion =>
               if Asked.Operands.Is_Empty or else Asked.Operands.Element (1)
                 not in "bash" | "zsh" | "fish"
               then
                  Refuse ("completion requires bash, zsh or fish");
               else
                  Result.Output := US.To_Unbounded_String
                    (C.Shell_Completion (Asked.Operands.Element (1)));
               end if;
            when C.Run =>
               Prepare_Run;
               if US.Length (Run_Directory) > 0 then
                  for Text of Asked.Operands loop
                     Forwarded.Append
                       ((if Text'Length > 0 and then Text (Text'First) = '-'
                         then "./" else "") & Text);
                  end loop;
                  begin
                     if Asked.Verbosity >= 2 then
                        declare
                           Wrapped : Tracing.Runner
                             (Tools'Access, Transcript'Access);
                        begin
                           Result := Landin.Driver.Execute
                             (Forwarded, Host, Wrapped, Meter, Built_For,
                              Warnings => Asked.Policy);
                        end;
                     else
                        Result := Landin.Driver.Execute
                          (Forwarded, Host, Tools, Meter, Built_For,
                           Warnings => Asked.Policy);
                     end if;
                  exception
                     when others =>
                        declare
                           Removed : Landin.Platform.Remove_Status;
                        begin
                           Host.Remove_Tree
                             (US.To_String (Run_Directory), Removed);
                        end;
                        raise;
                  end;
                  if Asked.Verbosity > 0 then
                     US.Append (Transcript, "refine run: host=" & Built_For
                       & "; target="
                       & Landin.Targets.Name
                           (Landin.Targets.Selection.Host_Default (Built_For))
                       & "; build-mode=" & Effective (C.Build_Mode, "debug")
                       & "; optimize=" & Effective (C.Optimize, "size")
                       & "; specialize=" & Effective (C.Specialize, "auto")
                       & "; debug=" & Effective (C.Debug, "none")
                       & "; link=" & Effective (C.Link, Default_Link)
                       & "; executable=" & US.To_String (Run_Directory) & "/"
                       & Program_Name (Asked.Operands.First_Element) & LF);
                     for Text of Asked.Forwarded loop
                        US.Append (Transcript, "  " & J.Quoted (Text) & LF);
                     end loop;
                  end if;
                  Result.Trace := Transcript & Result.Trace;
                  Finish_Run;
               end if;
            when C.Check | C.Compile | C.Format | C.Explain | C.Server =>
               if Asked.Command = C.Compile and then not Asked.Legacy then
                  declare
                     Has_Emit : Boolean := False;
                  begin
                     for Text of Forwarded loop
                        if Ada.Strings.Fixed.Index (Text, "--emit=") = 1 then
                           Has_Emit := True;
                        end if;
                     end loop;
                     if not Has_Emit then
                        Forwarded.Append ("--emit=exe");
                     end if;
                  end;
               elsif Asked.Command in C.Format | C.Explain | C.Server then
                  Forwarded.Prepend (C.Name (Asked.Command));
               end if;
               for Text of Asked.Operands loop
                  --  Legacy parsers see leading '-' as an option; a relative
                  --  path keeps the same file while making its role explicit.
                  Forwarded.Append
                    ((if Text'Length > 0 and then Text (Text'First) = '-'
                      then "./"
                      elsif Text in "fmt" | "explain" | "lsp"
                      then "./" else "") & Text);
               end loop;
               if Asked.Verbosity >= 2 then
                  declare
                     Wrapped : Tracing.Runner
                       (Tools'Access, Transcript'Access);
                  begin
                     Result := Landin.Driver.Execute
                       (Forwarded, Host, Wrapped, Meter, Built_For,
                        Asked.Dry_Run, US.To_String (Asked.Depfile),
                        Asked.Policy);
                  end;
               else
                  Result := Landin.Driver.Execute
                    (Forwarded, Host, Tools, Meter, Built_For,
                     Asked.Dry_Run, US.To_String (Asked.Depfile),
                        Asked.Policy);
               end if;
               if Asked.Verbosity > 0 then
                  US.Append (Transcript, "refine " & C.Name (Asked.Command)
                    & ": host=" & Built_For & "; target="
                    & Effective (C.Target,
                      (if Landin.Targets.Selection.Has_Host_Default (Built_For)
                       then Landin.Targets.Name
                         (Landin.Targets.Selection.Host_Default (Built_For))
                       else "unknown"))
                    & "; build-mode=" & Effective (C.Build_Mode, "debug")
                    & "; optimize=" & Effective (C.Optimize, "size")
                    & "; specialize=" & Effective (C.Specialize, "auto")
                    & "; debug=" & Effective (C.Debug, "none")
                    & (if Asked.Command = C.Compile
                       then "; link=" & Effective (C.Link, Default_Link)
                       else "")
                    --  D363: which library the request reads, since a
                    --  copied compiler finds none and says so here.
                    & "; library="
                    & Effective (C.Library,
                        (if Landin.Driver.Library.Located (Host) = ""
                         then "none"
                         else Landin.Driver.Library.Located (Host)))
                    & LF);
                  for Text of Asked.Forwarded loop
                     US.Append (Transcript, "  " & J.Quoted (Text) & LF);
                  end loop;
               end if;
               Result.Trace := Transcript & Result.Trace;
            when C.Help => null;
         end case;
      end if;
      Presentation.Render
        (Result, Asked.Style,
         US.To_String (Asked.Color) = "always"
         or else (US.To_String (Asked.Color) = "auto" and Terminal_Color));
      --  D526: bare `refine FILE` checked and wrote nothing, which a
      --  reader looking for an executable is told, with how to make one.
      if Asked.Legacy and then Asked.Command = C.Check
        and then US.Length (Asked.Problem) = 0
        and then not Asked.Wants_Help
        and then Result.Status = Landin.Driver.Status_Success
        and then not Asked.Quiet
        and then Asked.Style not in Presentation.JSON
        and then not Asked.Operands.Is_Empty
      then
         declare
            Named : US.Unbounded_String;
         begin
            for Text of Asked.Operands loop
               US.Append (Named,
                 (if US.Length (Named) = 0 then "" else " ") & Text);
            end loop;
            US.Append (Result.Report, "refine: checked "
              & US.To_String (Named) & " and wrote nothing; run it with"
              & " `refine run " & US.To_String (Named) & "`, or build it"
              & " with `refine compile " & US.To_String (Named) & " -o "
              & Program_Name (Asked.Operands.First_Element) & "`" & LF);
         end;
      end if;
      return Result;
   end Execute;

   procedure Launch
     (Result : in out Landin.Driver.Outcome;
      Host   : Landin.Platform.Filesystem'Class;
      Tools  : Landin.Platform.Tool_Runner'Class)
   is
      use type Landin.Platform.Termination;
      use type Landin.Platform.Remove_Status;
      Program : constant String := US.To_String (Result.Launch_Program);
      Directory : constant String := US.To_String (Result.Launch_Directory);
      Arguments : constant Landin.Platform.Path_List :=
        Result.Launch_Arguments;
      Ran : Landin.Platform.Program_Result;
      Removed : Landin.Platform.Remove_Status;
      Why : US.Unbounded_String;
      Started : Boolean := True;
   begin
      if Program = "" then
         return;
      end if;
      Result.Output := US.Null_Unbounded_String;
      Result.Report := US.Null_Unbounded_String;
      Result.Trace := US.Null_Unbounded_String;
      Result.Launch_Program := US.Null_Unbounded_String;
      Result.Launch_Directory := US.Null_Unbounded_String;
      Result.Launch_Arguments.Clear;
      begin
         Tools.Run_Attached (Program, Arguments, Ran);
      exception
         when Failure : Landin.External_Tool_Failed =>
            Started := False;
            Why := US.To_Unbounded_String
              (Ada.Exceptions.Exception_Message (Failure));
         when others =>
            Host.Remove_Tree (Directory, Removed);
            raise;
      end;
      Host.Remove_Tree (Directory, Removed);
      if not Started then
         Result.Status := Landin.Driver.Status_Reported;
         Result.Report := "refine: " & Why & LF;
      elsif Ran.Ended = Landin.Platform.Signaled then
         Result.Status := 128 + Ran.Signal;
         Result.Report := US.To_Unbounded_String
           ("refine: " & Program_Name (Program) & " was ended by "
            & US.To_String (Ran.Signal_Name) & " (signal"
            & Natural'Image (Ran.Signal) & ")" & LF);
      else
         Result.Status := Natural (Ran.Exit_Code);
      end if;
      if Removed = Landin.Platform.Not_Removable then
         US.Append (Result.Report,
           "refine: cannot remove " & Directory & LF);
      end if;
   end Launch;
end Landin.Commands;
