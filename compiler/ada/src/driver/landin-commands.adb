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
with Landin.Json;
with Landin.Source;
with Landin.Source.Sets;
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
      Problem : US.Unbounded_String;
   end record;

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
      Literal : Boolean := False;
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
            Text : constant String := Expanded.Element (Index);
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
                     Refuse
                       ("command-specific options must follow the command");
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
                  Refuse ("command-specific options must follow the command");
               end if;
            elsif not Literal and then not Result.Explicit_Command
              and then Result.Operands.Is_Empty and then Text = "build"
            then
               Refuse ("build is reserved for future project orchestration");
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
               Refuse (C.Name (Flag) & " requires its own command");
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
      procedure Identify;
      procedure Identify is
         B : J.Builder;
      begin
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
            J.End_Object (B);
            Result.Output := US.To_Unbounded_String (J.Result (B) & LF);
         else
            Result.Output := US.To_Unbounded_String
              (Version_Banner
                 (Landin.Build_Identity.Release_Version,
                  Landin.Build_Identity.Revision,
                  Landin.Build_Identity.Source_Digest,
                  Landin.Build_Identity.Dirty) & LF);
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
                    & "; debug=" & Effective (C.Debug, "none") & LF);
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
      return Result;
   end Execute;
end Landin.Commands;
