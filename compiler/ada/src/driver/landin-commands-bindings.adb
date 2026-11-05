with Ada.Exceptions;
with Ada.Strings.Fixed;
with GNAT.SHA256;

with Landin.Bindings;
with Landin.Diagnostics;
with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Text;
with Landin.Platform.Publication;
with Landin.Source;
with Landin.Source.Sets;
with Landin.Targets;
with Landin.Targets.Selection;

package body Landin.Commands.Bindings is

   package US renames Ada.Strings.Unbounded;
   package B renames Landin.Bindings;
   package Cat renames Landin.Diagnostics.Catalogue;
   package Platform renames Landin.Platform;
   package Pub renames Landin.Platform.Publication;

   use type Platform.Read_Status;
   use type Platform.Write_Status;
   use type Platform.Termination;
   use type B.Fault_Kind;
   use type B.Target;

   LF : constant Character := ASCII.LF;

   Staged_Suffix : constant String := ".refine-new";
   Kept_Suffix : constant String := ".refine-old";

   function Starts_With (Text, Prefix : String) return Boolean is
     (Text'Length >= Prefix'Length
      and then Text (Text'First .. Text'First + Prefix'Length - 1) = Prefix);

   function Number (Value : Positive) return String is
     (Positive'Image (Value) (2 .. Positive'Image (Value)'Last));

   function Contains (Text : String; Item : Character) return Boolean is
     (for some Each of Text => Each = Item);

   --  Path's components without empty and `.` ones, `..` taking the one
   --  before it: the lexical form of a path, links unresolved.
   function Normal (Path : String) return String;

   function Normal (Path : String) return String is
      Parts : Platform.Path_List;
      First : Positive := Path'First;
      Result : US.Unbounded_String;
   begin
      for Index in Path'First .. Path'Last + 1 loop
         if Index > Path'Last or else Path (Index) = '/' then
            declare
               Part : constant String := Path (First .. Index - 1);
            begin
               if Part = ".." then
                  if not Parts.Is_Empty then
                     Parts.Delete_Last;
                  end if;
               elsif Part /= "" and then Part /= "." then
                  Parts.Append (Part);
               end if;
            end;
            First := Index + 1;
         end if;
      end loop;
      for Part of Parts loop
         US.Append (Result, "/" & Part);
      end loop;
      if US.Length (Result) = 0 then
         return "/";
      end if;
      return US.To_String (Result);
   end Normal;

   --  The last component of a path, as Python's Path.name.
   function Base_Name (Path : String) return String;

   function Base_Name (Path : String) return String is
      Last : Natural := Path'Last;
      First : Positive;
   begin
      while Last >= Path'First and then Path (Last) = '/' loop
         Last := Last - 1;
      end loop;
      First := Path'First;
      for Index in Path'First .. Last loop
         if Path (Index) = '/' then
            First := Index + 1;
         end if;
      end loop;
      return Path (First .. Last);
   end Base_Name;

   --  A logical include name: relative, canonical, no `..`, and safe in a
   --  quoted `#include`.
   function Canonical_Logical (Name : String) return Boolean;

   function Canonical_Logical (Name : String) return Boolean is
      First : Positive := Name'First;
   begin
      if Name = "" or else Name (Name'First) = '/' then
         return False;
      end if;
      for Index in Name'First .. Name'Last + 1 loop
         if Index > Name'Last or else Name (Index) = '/' then
            declare
               Part : constant String := Name (First .. Index - 1);
            begin
               if Part = "" or else Part = "." or else Part = ".." then
                  return False;
               end if;
            end;
            First := Index + 1;
         end if;
      end loop;
      return True;
   end Canonical_Logical;

   function Printable (Text : String) return Boolean is
     (for all Each of Text =>
        Character'Pos (Each) >= 32 and then Character'Pos (Each) /= 127);

   function Is_Define (Text : String) return Boolean;

   function Is_Define (Text : String) return Boolean is
      Last : Natural := Text'First - 1;
   begin
      if Text = "" or else Text (Text'First) not in 'A' .. 'Z' | 'a' .. 'z'
                                                   | '_'
      then
         return False;
      end if;
      while Last + 1 <= Text'Last
        and then Text (Last + 1) in 'A' .. 'Z' | 'a' .. 'z' | '0' .. '9' | '_'
      loop
         Last := Last + 1;
      end loop;
      return Last = Text'Last or else Text (Last + 1) = '=';
   end Is_Define;

   function Define_Name (Text : String) return String;

   function Define_Name (Text : String) return String is
   begin
      for Index in Text'Range loop
         if Text (Index) = '=' then
            return Text (Text'First .. Index - 1);
         end if;
      end loop;
      return Text;
   end Define_Name;

   procedure Generate
     (Asked     : Request;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Built_For : String;
      Result    : in out Landin.Driver.Outcome)
   is
      None : Landin.Source.Sets.Source_Set;
      Session : B.Session;
      Chosen : B.Target := B.Linux_X86_64;
      Clang : US.Unbounded_String;
      Logical_Names, Header_Paths, Header_Bytes : Platform.Path_List;
      Sysroot : US.Unbounded_String;
      Include_Dirs, System_Include_Dirs : Platform.Path_List;
      Out_Dir : US.Unbounded_String;
      Work : US.Unbounded_String;
      Has_Work : Boolean := False;
      Group : Pub.Transaction;
      Has_Group : Boolean := False;
      Input_Paths : Platform.Path_List := Asked.Protected_Inputs;
      Policy_Text : US.Unbounded_String;

      procedure Report (Code : Cat.Code_Name; Message : String);

      procedure Report (Code : Cat.Code_Name; Message : String) is
      begin
         Result.Status := Landin.Driver.Status_Reported;
         Result.Found.Append
           (Landin.Diagnostics.Make
              (Code => Cat.Code (Code), Level => Landin.Diagnostics.Error,
               Source => Landin.Source.No_Source,
               Where => Landin.Source.Empty_Span, Message => Message));
         Result.Report := US.To_Unbounded_String
           (Landin.Diagnostics.Text.Render (Result.Found, None));
      end Report;

      procedure Read_Input
        (Path : String; Content : out US.Unbounded_String;
         Status : out Platform.Read_Status);

      procedure Read_Input
        (Path : String; Content : out US.Unbounded_String;
         Status : out Platform.Read_Status)
      is
         Identity : Platform.File_Identity;
      begin
         Host.Read_Snapshot (Path, Content, Identity, Status);
         if Status = Platform.Read_Ok then
            Pub.Protect (Group, Path, Identity);
            if not Input_Paths.Contains (Path) then
               Input_Paths.Append (Path);
            end if;
         end if;
      end Read_Input;

      --  A request refine cannot carry out as written, refused as a
      --  command line is.
      procedure Refuse (Message : String);

      procedure Refuse (Message : String) is
      begin
         Report (Cat.Unknown_Option, Message);
         Result.Status := Landin.Driver.Status_Misuse;
      end Refuse;

      function Absolute (Path : String) return String;

      function Absolute (Path : String) return String is
      begin
         if Starts_With (Path, "/") or else Host.Working_Directory = "" then
            return (if Starts_With (Path, "/") then Normal (Path) else Path);
         end if;
         return Normal (Host.Working_Directory & "/" & Path);
      end Absolute;

      function Repr (Text : String) return String renames B.Quoted;

      --  Check the request and read its inputs; false when it is refused.
      function Prepare return Boolean;

      function Prepare return Boolean is
         Read : Platform.Read_Status;
         Defines_Seen : Platform.Path_List;
      begin
         declare
            Named : constant String :=
              (if US.Length (Asked.Target) > 0
               then US.To_String (Asked.Target)
               elsif Landin.Targets.Selection.Has_Host_Default (Built_For)
               then Landin.Targets.Name
                      (Landin.Targets.Selection.Host_Default (Built_For))
               else "");
            Found : Boolean := False;
         begin
            for Each in B.Target loop
               if B.Target_Name (Each) = Named then
                  Chosen := Each;
                  Found := True;
               end if;
            end loop;
            if not Found then
               Refuse ("refine bindings binds C for "
                       & B.Target_Name (B.Linux_X86_64) & ", "
                       & B.Target_Name (B.Linux_Arm64) & " and "
                       & B.Target_Name (B.Darwin_Arm64)
                       & (if Named = "" then
                            "; name one with --target"
                          else ", and --target names " & Named));
               return False;
            end if;
         end;
         for Operand of Asked.Headers loop
            declare
               Equal : Natural := 0;
            begin
               for Index in Operand'Range loop
                  if Operand (Index) = '=' then
                     Equal := Index;
                     exit;
                  end if;
               end loop;
               declare
                  Raw_Path : constant String :=
                    (if Equal = 0 then Operand
                     else Operand (Equal + 1 .. Operand'Last));
                  Logical : constant String :=
                    (if Equal = 0 then Base_Name (Operand)
                     else Operand (Operand'First .. Equal - 1));
               begin
                  if not Canonical_Logical (Logical) then
                     Refuse ("a header's logical name must be a canonical"
                             & " relative include path, got "
                             & Repr (Logical));
                     return False;
                  end if;
                  if Contains (Logical, '\') or else Contains (Logical, '"')
                    or else not Printable (Logical)
                  then
                     Refuse ("a header's logical name is not safe for"
                             & " #include: " & Repr (Logical));
                     return False;
                  end if;
                  if Logical_Names.Contains (Logical) then
                     Refuse ("two headers have the logical name "
                             & Repr (Logical));
                     return False;
                  end if;
                  declare
                     Path : constant String := Absolute (Raw_Path);
                     Bytes : US.Unbounded_String;
                  begin
                     if not Host.Exists (Path) or else Host.Is_Directory (Path)
                     then
                        Report (Cat.Unreadable_Source, "the header "
                                & Repr (Raw_Path) & " is not a regular file");
                        return False;
                     end if;
                     for Other of Header_Paths loop
                        if Other = Path or else Host.Same_File (Other, Path)
                        then
                           Refuse ("the header " & Path
                                   & " is selected twice");
                           return False;
                        end if;
                     end loop;
                     Read_Input (Path, Bytes, Read);
                     if Read /= Platform.Read_Ok then
                        Report (Cat.Unreadable_Source, "cannot read the"
                                & " header " & Repr (Logical));
                        return False;
                     end if;
                     Logical_Names.Append (Logical);
                     Header_Paths.Append (Path);
                     Header_Bytes.Append (US.To_String (Bytes));
                  end;
               end;
            end;
         end loop;
         for Value of Asked.Defines loop
            if not Is_Define (Value) or else not Printable (Value) then
               Refuse ("--define is not NAME or NAME=VALUE: " & Repr (Value));
               return False;
            end if;
            if Defines_Seen.Contains (Define_Name (Value)) then
               Refuse ("--define names " & Repr (Define_Name (Value))
                       & " twice");
               return False;
            end if;
            Defines_Seen.Append (Define_Name (Value));
         end loop;
         Sysroot := US.To_Unbounded_String
           (Absolute (US.To_String (Asked.Sysroot)));
         if not Host.Is_Directory (US.To_String (Sysroot)) then
            Report (Cat.Bindings_Clang_Refused, "--sysroot "
                    & Repr (US.To_String (Asked.Sysroot))
                    & " is not a directory; an empty one will do when no"
                    & " target system header is needed");
            return False;
         end if;
         for Pair in 1 .. 2 loop
            declare
               Given : constant Platform.Path_List :=
                 (if Pair = 1 then Asked.Include_Dirs
                  else Asked.System_Include_Dirs);
            begin
               for Value of Given loop
                  declare
                     Path : constant String := Absolute (Value);
                  begin
                     if not Host.Is_Directory (Path) then
                        Report (Cat.Bindings_Clang_Refused,
                                (if Pair = 1 then "--include-dir "
                                 else "--system-include-dir ")
                                & Repr (Value) & " is not a directory");
                        return False;
                     end if;
                     if Pair = 1 then
                        Include_Dirs.Append (Path);
                     else
                        System_Include_Dirs.Append (Path);
                     end if;
                  end;
               end loop;
            end;
         end loop;
         declare
            Policy_Path : constant String :=
              Absolute (US.To_String (Asked.Policy));
         begin
            if not Host.Exists (Policy_Path)
              or else Host.Is_Directory (Policy_Path)
            then
               Report (Cat.Unreadable_Source, "the policy "
                       & Repr (US.To_String (Asked.Policy))
                       & " is not a regular file");
               return False;
            end if;
            Read_Input (Policy_Path, Policy_Text, Read);
            if Read /= Platform.Read_Ok then
               Report (Cat.Unreadable_Source, "cannot read the policy "
                       & US.To_String (Asked.Policy));
               return False;
            end if;
         end;
         declare
            Written : constant String := US.To_String (Asked.Out_Dir);
            Trimmed : Natural := Written'Last;
         begin
            while Trimmed > Written'First and then Written (Trimmed) = '/' loop
               Trimmed := Trimmed - 1;
            end loop;
            Out_Dir := US.To_Unbounded_String
              (if Starts_With (Written, "/") or else Host.Working_Directory
                = ""
               then Written (Written'First .. Trimmed)
               else Host.Working_Directory & "/"
                    & Written (Written'First .. Trimmed));
         end;
         return True;
      end Prepare;

      function Destination (Index : B.Output_Index) return String is
        (US.To_String (Out_Dir) & "/" & B.Output_Name (Index));

      --  Every destination: the directory is one, or is not there, and is
      --  no link; each output is a file or is not there; no earlier run
      --  left its copies.
      function Preflight return Boolean;

      function Preflight return Boolean is
         Root : constant String := US.To_String (Out_Dir);
      begin
         if Host.Is_Link (Root) then
            Report (Cat.Bindings_Output_Refused,
                    "the output directory " & Root & " is a symbolic link;"
                    & " name the directory it leads to with --out-dir");
            return False;
         end if;
         if Host.Exists (Root) and then not Host.Is_Directory (Root) then
            Report (Cat.Bindings_Output_Refused,
                    "the output directory " & Root & " is not a directory;"
                    & " remove it, or name another with --out-dir");
            return False;
         end if;
         for Index in B.Output_Index loop
            declare
               Path : constant String := Destination (Index);
            begin
               if Host.Exists (Path)
                 and then Host.Paths_Overlap_Any (Path, Input_Paths)
               then
                  Report (Cat.Bindings_Output_Refused,
                          Path & " overlaps an input; name another output"
                          & " directory with --out-dir");
                  return False;
               end if;
               if Host.Is_Link (Path) or else Host.Is_Directory (Path) then
                  Report (Cat.Bindings_Output_Refused,
                          "cannot publish " & B.Output_Name (Index)
                          & ": existing output is not a regular file");
                  return False;
               end if;
               for Suffix of Platform.Path_List'[Staged_Suffix, Kept_Suffix]
               loop
                  if Host.Exists (Path & Suffix)
                    or else Host.Is_Link (Path & Suffix)
                  then
                     Report (Cat.Bindings_Output_Refused,
                             Path & Suffix & " was left by an interrupted"
                             & " run of refine bindings; compare it with "
                             & Path & ", keep the one you want, and remove"
                             & " it");
                     return False;
                  end if;
               end loop;
            end;
         end loop;
         return True;
      end Preflight;

      function Work_Path (Name : String) return String is
        (US.To_String (Work) & "/" & Name);

      --  Native Clang runs in the retained work directory. Its relative
      --  dependency names refer there, even when the original TMPDIR moved.
      function Clang_Path (Path : String) return String;

      function Clang_Path (Path : String) return String is
         Root : constant String := Normal (US.To_String (Work));
         Resolved : constant String :=
           (if Starts_With (Path, "/") then Normal (Path)
            else Normal (Work_Path (Path)));
         Depth : Natural := 0;
         First : Positive := Path'First;
         Escapes : Boolean := False;
      begin
         if Starts_With (Path, "/") then
            return Resolved;
         end if;
         for Index in Path'First .. Path'Last + 1 loop
            if Index > Path'Last or else Path (Index) = '/' then
               declare
                  Part : constant String := Path (First .. Index - 1);
               begin
                  if Part = ".." then
                     if Depth = 0 then
                        Escapes := True;
                        exit;
                     end if;
                     Depth := Depth - 1;
                  elsif Part /= "" and then Part /= "." then
                     Depth := Depth + 1;
                  end if;
               end;
               First := Index + 1;
            end if;
         end loop;
         if Escapes or else not Starts_With (Resolved, Root & "/") then
            Report
              (Cat.Bindings_Clang_Refused, "Clang reported a relative header"
               & " outside its private workspace: " & Repr (Path)
               & "; use an absolute include path, or include the header"
               & " by a name under --include-dir or --system-include-dir");
            return "";
         end if;
         --  Keep the registered spelling after normalizing components
         --  inside the work root, so a moved ancestor is never reopened.
         return US.To_String (Work)
           & Resolved (Root'Last + 1 .. Resolved'Last);
      end Clang_Path;

      --  What every Clang run is given before its own arguments.
      function Base_Arguments return Platform.Path_List;

      function Base_Arguments return Platform.Path_List is
         Arguments : Platform.Path_List;
         Roots, Logicals : Platform.Path_List;
      begin
         Arguments.Append ("--target=" & B.Triple (Chosen));
         Arguments.Append ("--no-default-config");
         Arguments.Append ("--sysroot=" & US.To_String (Sysroot));
         Arguments.Append ("-std=c11");
         Arguments.Append ("-fno-short-enums");
         Arguments.Append ("-nostdinc");
         Arguments.Append ("-Wsystem-headers");
         Arguments.Append ("-Werror=date-time");
         Arguments.Append ("-iquote");
         Arguments.Append (Work_Path ("headers"));
         Roots.Append (US.To_String (Sysroot));
         Logicals.Append ("sysroot");
         Roots.Append (US.To_String (Work));
         Logicals.Append (".");
         for Index in 1 .. Natural (Include_Dirs.Length) loop
            Roots.Append (Include_Dirs (Index));
            Logicals.Append ("include/" & Number (Index));
         end loop;
         for Index in 1 .. Natural (System_Include_Dirs.Length) loop
            Roots.Append (System_Include_Dirs (Index));
            Logicals.Append ("system/" & Number (Index));
         end loop;
         --  Clang applies the last matching map, so the most specific
         --  root goes last: shortest first, in the order given among
         --  equals.
         declare
            Placed : array (1 .. Natural (Roots.Length)) of Boolean :=
              [others => False];
         begin
            for Unused_Round in Placed'Range loop
               declare
                  Best : Natural := 0;
               begin
                  for Position in Placed'Range loop
                     if not Placed (Position)
                       and then (Best = 0
                                 or else Roots.Element (Position)'Length
                                         < Roots.Element (Best)'Length)
                     then
                        Best := Position;
                     end if;
                  end loop;
                  Placed (Best) := True;
                  Arguments.Append
                    ("-ffile-prefix-map=" & Roots (Best) & "="
                     & Logicals (Best));
               end;
            end loop;
         end;
         for Directory of Include_Dirs loop
            Arguments.Append ("-I");
            Arguments.Append (Directory);
         end loop;
         for Directory of System_Include_Dirs loop
            Arguments.Append ("-isystem");
            Arguments.Append (Directory);
         end loop;
         for Define of Asked.Defines loop
            Arguments.Append ("-D" & Define);
         end loop;
         return Arguments;
      end Base_Arguments;

      --  Clang's error output with the host's paths replaced by names that
      --  do not depend on where the request ran.
      function Sanitize (Text : String) return String;

      function Sanitize (Text : String) return String is
         Olds, News : Platform.Path_List;
         Current : US.Unbounded_String := US.To_Unbounded_String (Text);
      begin
         Olds.Append (Work_Path ("headers"));
         News.Append ("<headers>");
         Olds.Append (US.To_String (Work));
         News.Append ("<work>");
         for Index in 1 .. Natural (Header_Paths.Length) loop
            Olds.Append (Header_Paths (Index));
            News.Append (Logical_Names (Index));
         end loop;
         Olds.Append (US.To_String (Sysroot));
         News.Append ("<sysroot>");
         for Index in 1 .. Natural (Include_Dirs.Length) loop
            Olds.Append (Include_Dirs (Index));
            News.Append ("<include-" & Number (Index) & ">");
         end loop;
         for Index in 1 .. Natural (System_Include_Dirs.Length) loop
            Olds.Append (System_Include_Dirs (Index));
            News.Append ("<system-include-" & Number (Index) & ">");
         end loop;
         declare
            Done : array (1 .. Natural (Olds.Length)) of Boolean :=
              [others => False];
         begin
            for Unused_Round in Done'Range loop
               declare
                  Best : Natural := 0;
               begin
                  for Position in Done'Range loop
                     if not Done (Position)
                       and then (Best = 0
                                 or else Olds.Element (Position)'Length
                                         > Olds.Element (Best)'Length)
                     then
                        Best := Position;
                     end if;
                  end loop;
                  Done (Best) := True;
                  declare
                     Old : constant String := Olds (Best);
                     Replaced : US.Unbounded_String;
                     Index : Natural := 1;
                     Source : constant String := US.To_String (Current);
                  begin
                     if Old /= "" then
                        while Index <= Source'Length loop
                           if Index + Old'Length - 1 <= Source'Length
                             and then Source (Index .. Index + Old'Length - 1)
                                      = Old
                           then
                              US.Append (Replaced, News (Best));
                              Index := Index + Old'Length;
                           else
                              US.Append (Replaced, Source (Index));
                              Index := Index + 1;
                           end if;
                        end loop;
                        Current := Replaced;
                     end if;
                  end;
               end;
            end loop;
         end;
         return US.To_String (Current);
      end Sanitize;

      Environment : constant Platform.Path_List :=
        ["PATH", "HOME", "TMPDIR", "TMP", "TEMP", "SystemRoot", "LC_ALL=C",
         "TZ=UTC"];

      --  Run Clang with Extra after the base arguments; false, reported,
      --  when it cannot be run or fails.
      function Run_Clang
        (Extra : Platform.Path_List; Context : String;
         Output : out US.Unbounded_String) return Boolean;

      function Run_Clang
        (Extra : Platform.Path_List; Context : String;
         Output : out US.Unbounded_String) return Boolean
      is
         Arguments : Platform.Path_List := Base_Arguments;
         Ran : Platform.Tool_Result;
      begin
         Output := US.Null_Unbounded_String;
         Arguments.Append (Extra);
         begin
            Tools.Run_In_Environment
              (US.To_String (Clang), Arguments, Environment, Ran,
               Platform.Output_Only);
         exception
            when Failure : External_Tool_Failed =>
               Report (Cat.Bindings_Clang_Refused,
                       Ada.Exceptions.Exception_Message (Failure)
                       & "; cannot execute Clang " & US.To_String (Clang));
               return False;
         end;
         if Ran.Ended /= Platform.Exited or else Ran.Exit_Code /= 0 then
            declare
               Detail : constant String :=
                 Sanitize (US.To_String (Ran.Error_Output));
               First : Positive := Detail'First;
               Last : Natural := Detail'Last;
            begin
               while First <= Last
                 and then Detail (First) in ' ' | LF | ASCII.HT | ASCII.CR
               loop
                  First := First + 1;
               end loop;
               while Last >= First
                 and then Detail (Last) in ' ' | LF | ASCII.HT | ASCII.CR
               loop
                  Last := Last - 1;
               end loop;
               Report (Cat.Bindings_Clang_Refused, "Clang failed while "
                       & Context & ":" & LF & Detail (First .. Last));
            end;
            return False;
         end if;
         Output := Ran.Output;
         return True;
      end Run_Clang;

      function Report_Fault return Boolean;

      --  When the session has failed, report why; true when it has.
      function Report_Fault return Boolean is
      begin
         if B.Ok (Session) then
            return False;
         end if;
         Report
           ((case B.Fault (Session) is
               when B.Policy_Fault => Cat.Bindings_Policy_Invalid,
               when B.Clang_Fault => Cat.Bindings_Clang_Refused,
               when B.Declaration_Fault | B.No_Fault =>
                  Cat.Bindings_Declaration_Refused),
            B.Message (Session));
         return True;
      end Report_Fault;

      function Write (Path, Content : String) return Boolean;

      function Write (Path, Content : String) return Boolean is
         Written : Platform.Write_Status;
      begin
         Host.Write_File (Path, Content, Written);
         if Written /= Platform.Write_Ok then
            Report (Cat.Unwritable_Output, "cannot write " & Path);
            return False;
         end if;
         return True;
      end Write;

      --  Make Path and every directory above it that is not there.
      function Make_Directories (Path : String) return Boolean;

      function Make_Directories (Path : String) return Boolean is
         Made : Platform.Write_Status;
      begin
         for Index in Path'First + 1 .. Path'Last + 1 loop
            if Index > Path'Last or else Path (Index) = '/' then
               declare
                  Prefix : constant String := Path (Path'First .. Index - 1);
               begin
                  if not Host.Is_Directory (Prefix) then
                     Host.Make_Directory (Prefix, Made);
                     if Made /= Platform.Write_Ok then
                        return False;
                     end if;
                  end if;
               end;
            end if;
         end loop;
         return True;
      end Make_Directories;

      --  Bind: everything Clang is asked and the four outputs, staged and
      --  compiled in the work directory.
      function Bind return Boolean;

      function Bind return Boolean is
         Made : Platform.Write_Status;
         Triple_Output, Macros, Preprocessed, Ast : US.Unbounded_String;
         Stripped, Probe, Probe_Output, Dependencies : US.Unbounded_String;
         Headers : B.Header_Vectors.Vector;
         Roots : Platform.Path_List;
      begin
         B.Load_Policy (Session, US.To_String (Policy_Text));
         if Report_Fault then
            return False;
         end if;
         if B.Policy_Triple (Session) /= B.Triple (Chosen) then
            Report (Cat.Bindings_Policy_Invalid, "the policy binds for "
                    & B.Policy_Triple (Session) & ", and --target names "
                    & B.Target_Name (Chosen) & ", which is "
                    & B.Triple (Chosen));
            return False;
         end if;
         Host.Make_Private_Directory ("refine-bindings-", Work, Made);
         if Made /= Platform.Write_Ok then
            Report (Cat.Unwritable_Output, "cannot make a private directory"
                    & " under TMPDIR or /tmp to run Clang in");
            return False;
         end if;
         Has_Work := True;
         if not Make_Directories (Work_Path ("headers")) then
            Report (Cat.Unwritable_Output, "cannot make "
                    & Work_Path ("headers"));
            return False;
         end if;
         declare
            Translation : US.Unbounded_String := US.To_Unbounded_String
              ("/* Synthetic translation unit for Landin binding"
               & " generation. */" & LF);
         begin
            for Index in 1 .. Natural (Logical_Names.Length) loop
               declare
                  Path : constant String :=
                    Work_Path ("headers/" & Logical_Names (Index));
                  Last_Slash : Natural := 0;
               begin
                  for Position in Path'Range loop
                     if Path (Position) = '/' then
                        Last_Slash := Position;
                     end if;
                  end loop;
                  if not Make_Directories (Path (Path'First .. Last_Slash - 1))
                  then
                     Report (Cat.Unwritable_Output, "cannot make the"
                             & " directory of " & Path);
                     return False;
                  end if;
                  if not Write (Path, Header_Bytes (Index)) then
                     return False;
                  end if;
                  US.Append (Translation, "#include """
                             & Logical_Names (Index) & """" & LF);
                  Headers.Append
                    (B.Header'(Logical => US.To_Unbounded_String
                                   (Logical_Names (Index)),
                      Digest => US.To_Unbounded_String
                        (GNAT.SHA256.Digest (Header_Bytes (Index)))));
               end;
            end loop;
            if not Write (Work_Path ("translation.c"),
                          US.To_String (Translation))
              or else not Write (Work_Path ("empty.c"), "")
            then
               return False;
            end if;
         end;
         if not Run_Clang (["-print-target-triple"],
                           "querying the target triple", Triple_Output)
         then
            return False;
         end if;
         B.Check_Triple (Session, Chosen, US.To_String (Triple_Output));
         if Report_Fault
           or else not Run_Clang
             (["-dM", "-E", "-x", "c", Work_Path ("empty.c")],
              "probing the target ABI", Macros)
         then
            return False;
         end if;
         B.Check_Macros (Session, Chosen, US.To_String (Macros));
         if Report_Fault then
            return False;
         end if;
         if not Run_Clang (["-E", Work_Path ("translation.c")],
                           "preprocessing selected headers", Preprocessed)
         then
            return False;
         end if;
         Roots.Append (US.To_String (Sysroot));
         Roots.Append (US.To_String (Work));
         Roots.Append (Include_Dirs);
         Roots.Append (System_Include_Dirs);
         for Path of B.Marker_Files (US.To_String (Preprocessed)) loop
            --  Clang reports dependency names, not its read descriptors.
            --  Invocation-owned header copies and probes are disposable.
            declare
               Location : constant String := Clang_Path (Path);
            begin
               if Location = "" then
                  return False;
               elsif not Starts_With (Location, US.To_String (Work) & "/") then
                  Pub.Protect (Group, Host, Location);
                  Input_Paths.Append (Location);
               end if;
            end;
         end loop;
         B.Strip_Markers
           (Session, US.To_String (Preprocessed), Roots, Stripped);
         if Report_Fault
           or else not Write (Work_Path ("translation.i"),
                              US.To_String (Stripped))
         then
            return False;
         end if;
         if not Run_Clang
             (["-Xclang", "-ast-dump=json", "-fsyntax-only",
               Work_Path ("translation.i")],
              "parsing selected headers", Ast)
         then
            return False;
         end if;
         B.Read_Ast (Session, US.To_String (Ast), Headers);
         if Report_Fault then
            return False;
         end if;
         if B.Needs_Probe (Session) then
            B.Probe_Source (Session, US.To_String (Stripped), Probe);
            if Report_Fault
              or else not Write (Work_Path ("enum-probe.i"),
                                 US.To_String (Probe))
              or else not Run_Clang
                (["-Xclang", "-ast-dump=json", "-Xclang",
                  B.Probe_Filter (Session), "-fsyntax-only",
                  Work_Path ("enum-probe.i")],
                 "probing enum types", Probe_Output)
            then
               return False;
            end if;
            B.Read_Probe (Session, US.To_String (Probe_Output));
            if Report_Fault then
               return False;
            end if;
         end if;
         B.Generate (Session, Asked.Defines);
         if Report_Fault then
            return False;
         end if;
         for Index in B.Output_Index loop
            for Path of Header_Paths loop
               if Starts_With (Path, "/")
                 and then Ada.Strings.Fixed.Index
                   (B.Output (Session, Index), Path) /= 0
               then
                  Report (Cat.Bindings_Declaration_Refused, "internal:"
                          & " generated output contains an absolute input"
                          & " path");
                  return False;
               end if;
            end loop;
         end loop;
         if not Make_Directories (Work_Path ("output")) then
            Report (Cat.Unwritable_Output, "cannot make "
                    & Work_Path ("output"));
            return False;
         end if;
         for Index in B.Output_Index loop
            if not Write (Work_Path ("output/" & B.Output_Name (Index)),
                          B.Output (Session, Index))
            then
               return False;
            end if;
         end loop;
         declare
            Validation : Platform.Path_List :=
              ["-iquote", Work_Path ("output"), "-Wall", "-Wextra", "-Werror",
               "-Wno-error=unused-command-line-argument", "-fsyntax-only",
               "-MD", "-MF", "-", "-MT", "refine-bindings"];
         begin
            --  SDK 26.5 mixes annotated and unannotated declarations in
            --  _stdlib.h, and -Wsystem-headers exposes their
            --  nullability-completeness warnings: they describe the SDK's
            --  annotations, not an adapter's pointer policy.
            if Chosen = B.Darwin_Arm64 then
               Validation.Append ("-Wno-nullability-completeness");
            end if;
            Validation.Append (Work_Path ("output/adapters.c"));
            if not Run_Clang (Validation, "validating generated adapters",
                              Dependencies)
            then
               return False;
            end if;
         end;
         declare
            Consumed : Platform.Path_List;
            Valid : Boolean;
         begin
            B.Dependency_Files (US.To_String (Dependencies), Consumed, Valid);
            if not Valid then
               Report (Cat.Bindings_Clang_Refused,
                       "Clang did not report the generated adapters' header"
                       & " dependencies; use a Clang that supports -MD -MF");
               return False;
            end if;
            for Path of Consumed loop
               declare
                  Location : constant String := Clang_Path (Path);
               begin
                  if Location = "" then
                     return False;
                  elsif not Starts_With (Location, US.To_String (Work) & "/")
                  then
                     Pub.Protect (Group, Host, Location);
                     Input_Paths.Append (Location);
                  end if;
               end;
            end loop;
         end;
         return True;
      end Bind;

      function Prepare_Outputs return Boolean;

      function Prepare_Outputs return Boolean is
         Status : Platform.Write_Status;
         Reason : US.Unbounded_String;
      begin
         Has_Group := True;
         for Index in B.Output_Index loop
            Pub.Prepare (Group, Host, Destination (Index), Status, Reason,
                         Root => US.To_String (Out_Dir));
            if Status /= Platform.Write_Ok then
               Report (Cat.Bindings_Output_Refused, US.To_String (Reason));
               return False;
            end if;
         end loop;
         return True;
      end Prepare_Outputs;

      procedure Replace;

      procedure Replace is
         Status : Platform.Write_Status;
         Read : Platform.Read_Status;
         Reason, Existing : US.Unbounded_String;
         Changed : Natural := 0;
      begin
         for Index in B.Output_Index loop
            declare
               Path : constant String := Destination (Index);
               Content : constant String := B.Output (Session, Index);
            begin
               Host.Read_File (Path, Existing, Read);
               if Read /= Platform.Read_Ok
                 or else US.To_String (Existing) /= Content
               then
                  Changed := Changed + 1;
               end if;
               if not Write (Pub.Stage_Path (Group, Path), Content) then
                  return;
               end if;
               Host.Read_File (Pub.Stage_Path (Group, Path), Existing, Read);
               if Read /= Platform.Read_Ok
                 or else US.To_String (Existing) /= Content
               then
                  Report (Cat.Unwritable_Output,
                          "cannot read back " & Pub.Stage_Path (Group, Path)
                          & "; nothing was replaced");
                  return;
               end if;
            end;
         end loop;
         Pub.Commit (Group, Host, Status, Reason);
         if Status /= Platform.Write_Ok then
            Report (Cat.Unwritable_Output, US.To_String (Reason));
            return;
         end if;
         Pub.Finish (Group, Host, Status, Reason);
         Has_Group := False;
         if Status /= Platform.Write_Ok then
            Report (Cat.Unwritable_Output, US.To_String (Reason));
            return;
         end if;
         Result.Output := US.To_Unbounded_String
           ("refine bindings: 4 files under " & US.To_String (Out_Dir)
            & "," & Natural'Image (Changed) & " of them written" & LF);
      end Replace;

      procedure Clean_Up;

      procedure Clean_Up is
         use type Platform.Remove_Status;
         Removed : Platform.Remove_Status;
         Status : Platform.Write_Status;
         Reason : US.Unbounded_String;
      begin
         if Has_Group then
            Pub.Abort_Transaction (Group, Host, Status, Reason);
            Has_Group := False;
            if Status /= Platform.Write_Ok then
               Report (Cat.Unwritable_Output, US.To_String (Reason));
            end if;
         end if;
         if Has_Work then
            Host.Remove_Tree (US.To_String (Work), Removed);
            if Removed = Platform.Not_Removable then
               Report
                 (Cat.Unwritable_Output, "cannot remove private bindings work "
                  & US.To_String (Work) & ": " & Host.Removal_Failure_Reason);
            end if;
            Has_Work := False;
         end if;
      end Clean_Up;
   begin
      for Path of Asked.Protected_Inputs loop
         Pub.Protect (Group, Host, Path);
      end loop;
      for Identity of Asked.Protected_Identities loop
         Pub.Protect (Group, "", Identity);
      end loop;
      if not Prepare then
         return;
      end if;
      Clang := US.To_Unbounded_String
        (Tools.Resolve_Program (US.To_String (Asked.Clang)));
      if US.Length (Clang) = 0 then
         Report (Cat.Bindings_Clang_Refused, "cannot execute Clang "
                 & US.To_String (Asked.Clang)
                 & "; name an available executable with --clang");
         return;
      end if;
      Pub.Protect (Group, Host, US.To_String (Clang));
      Input_Paths.Append (US.To_String (Clang));
      if not Preflight then
         return;
      end if;
      begin
         if Prepare_Outputs and then Bind and then Preflight then
            Replace;
         end if;
      exception
         when others =>
            Clean_Up;
            raise;
      end;
      Clean_Up;
   end Generate;

end Landin.Commands.Bindings;
