with Ada.Strings.Fixed;
with Landin.Build_Identity;
with Landin.Diagnostics;
with Landin.Diagnostics.Suggestions;
with Landin.Diagnostics.Text;
with Landin.Json;
with Landin.Response_Files;
with Landin.Source;
with Landin.Source.Sets;

package body Landin.Splits is

   package J renames Landin.Json;
   package Presentation renames Landin.Presentation;
   use type US.Unbounded_String;
   LF : constant Character := ASCII.LF;

   function Flag (Name, Description : String) return Option is
     ((Name => US.To_Unbounded_String (Name),
       Value_Name => US.Null_Unbounded_String,
       Description => US.To_Unbounded_String (Description),
       Repeatable => False));

   function Valued
     (Name, Value_Name, Description : String;
      Repeatable : Boolean := False) return Option is
     ((Name => US.To_Unbounded_String (Name),
       Value_Name => US.To_Unbounded_String (Value_Name),
       Description => US.To_Unbounded_String (Description),
       Repeatable => Repeatable));

   function Given (Asked : Request; Index : Positive) return Boolean is
     (Index <= Natural (Asked.Values.Length)
      and then not Asked.Values (Index).Is_Empty);

   function Value (Asked : Request; Index : Positive) return String is
     (if Given (Asked, Index) then Asked.Values (Index).Last_Element else "");

   function Values
     (Asked : Request; Index : Positive) return Landin.Platform.Path_List is
     (if Index <= Natural (Asked.Values.Length) then Asked.Values (Index)
      else Landin.Platform.Path_Vectors.Empty_Vector);

   --  The shared options every command takes, as `refine` spells them.
   Shared_Help : constant String := "--help";
   Shared_Verbose : constant String := "--verbose";
   Shared_Quiet : constant String := "--quiet";
   Shared_Color : constant String := "--color";
   Shared_Diagnostics : constant String := "--diagnostics";

   Shared_Names : constant array (1 .. 5) of access constant String :=
     [new String'(Shared_Help), new String'(Shared_Verbose),
      new String'(Shared_Quiet), new String'(Shared_Color),
      new String'(Shared_Diagnostics)];

   function Long_Name (Written : String) return String is
     (if Written = "-h" then Shared_Help
      elsif Written = "-v" then Shared_Verbose
      elsif Written = "-q" then Shared_Quiet
      else Written);

   function Choices (Name : String) return String is
     (if Name = Shared_Color then "auto|always|never"
      elsif Name = Shared_Diagnostics then "human|short|json" else "");

   --  "auto, always or never" for "auto|always|never".
   function Spoken (Listed : String) return String;
   function Spoken (Listed : String) return String is
      Last_Bar : constant Natural :=
        Ada.Strings.Fixed.Index (Listed, "|", Ada.Strings.Backward);
      Text : US.Unbounded_String;
   begin
      for Index in Listed'Range loop
         if Listed (Index) /= '|' then
            US.Append (Text, Listed (Index));
         elsif Index = Last_Bar then
            US.Append (Text, " or ");
         else
            US.Append (Text, ", ");
         end if;
      end loop;
      return US.To_String (Text);
   end Spoken;

   function Value_Problem (Name, Written : String) return String is
     ((if Written = "" then Name & " needs a value"
       else Name & " does not take `" & Written & "`")
      & (if Choices (Name) = "" then ""
         else "; it takes " & Spoken (Choices (Name))));

   function Parse
     (Options   : Option_Array;
      Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class) return Request
   is
      Result : Request;
      Expanded : Landin.Platform.Path_List;
      Literal : Boolean := False;
      Seen_Color, Seen_Diagnostics : Boolean := False;
      Index : Positive := 1;

      procedure Refuse (Message : String);
      procedure Refuse (Message : String) is
      begin
         if US.Length (Result.Problem) = 0 then
            Result.Problem := US.To_Unbounded_String (Message);
         end if;
      end Refuse;

      --  The position of the command's option named Stem, or 0.
      function Own (Stem : String) return Natural;
      function Own (Stem : String) return Natural is
      begin
         for Position in Options'Range loop
            if US.To_String (Options (Position).Name) = Stem then
               return Position - Options'First + 1;
            end if;
         end loop;
         return 0;
      end Own;

      function Nearest (Stem : String) return String;
      function Nearest (Stem : String) return String is
         Offered : Landin.Diagnostics.Suggestions.Ranking;
      begin
         for Name of Shared_Names loop
            Landin.Diagnostics.Suggestions.Consider
              (Offered, Stem, Name.all);
         end loop;
         for Item of Options loop
            Landin.Diagnostics.Suggestions.Consider
              (Offered, Stem, US.To_String (Item.Name));
         end loop;
         if Landin.Diagnostics.Suggestions.Count (Offered) = 0 then
            return "";
         end if;
         return Landin.Diagnostics.Suggestions.Nth (Offered, 1);
      end Nearest;
   begin
      for Position in Options'Range loop
         Result.Values.Append (Landin.Platform.Path_Vectors.Empty_Vector);
      end loop;
      --  D1485: what `refine` asks of a split, read before anything else.
      if Natural (Arguments.Length) = 1
        and then Arguments.First_Element = "--describe"
      then
         Result.Wanted := Describe;
         return Result;
      elsif not Arguments.Is_Empty
        and then Arguments.First_Element = "--complete"
      then
         Result.Wanted := Complete;
         for Position in 2 .. Natural (Arguments.Length) loop
            if Position > 2 or else Arguments (Position) /= "--" then
               Result.Completed.Append (Arguments (Position));
            end if;
         end loop;
         return Result;
      end if;
      Landin.Response_Files.Expand
        (Arguments, Host, Expanded, Result.Problem,
         Result.Consumed_Response_Files, Result.Consumed_Response_Identities);
      if US.Length (Result.Problem) /= 0 then
         return Result;
      end if;
      while Index <= Natural (Expanded.Length) loop
         declare
            Text : constant String := Expanded.Element (Index);
            Equal : constant Natural := Ada.Strings.Fixed.Index (Text, "=");
            Stem : constant String := Long_Name
              (if Equal = 0 then Text else Text (Text'First .. Equal - 1));
            Position : constant Natural := Own (Stem);
            Takes_Value : constant Boolean :=
              Stem in Shared_Color | Shared_Diagnostics
              or else (Position /= 0
                and then US.Length
                  (Options (Options'First + Position - 1).Value_Name) > 0);
            Written : US.Unbounded_String;
         begin
            if not Literal and then Text = "--" then
               Literal := True;
            elsif not Literal and then Text = "-vv" then
               Result.Verbosity := Result.Verbosity + 2;
            elsif not Literal and then Text'Length > 0
              and then Text (Text'First) = '-'
            then
               if Position = 0 and then Stem not in Shared_Help
                 | Shared_Verbose | Shared_Quiet | Shared_Color
                 | Shared_Diagnostics
               then
                  Refuse ("unknown option: " & Text
                    & (if Nearest (Stem) = "" then ""
                       else "; did you mean " & Nearest (Stem) & "?"));
               elsif Takes_Value then
                  if Equal /= 0 then
                     Written := US.To_Unbounded_String
                       (Text (Equal + 1 .. Text'Last));
                  elsif Index < Natural (Expanded.Length)
                    and then Expanded.Element (Index + 1) /= "--"
                    and then (Expanded.Element (Index + 1)'Length = 0
                      or else Expanded.Element (Index + 1)
                        (Expanded.Element (Index + 1)'First) /= '-')
                  then
                     Index := Index + 1;
                     Written := US.To_Unbounded_String
                       (Expanded.Element (Index));
                  else
                     Refuse (Value_Problem (Stem, ""));
                  end if;
                  if Choices (Stem) /= "" then
                     if Ada.Strings.Fixed.Index
                       ("|" & Choices (Stem) & "|",
                        "|" & US.To_String (Written) & "|") = 0
                       or else Written = ""
                     then
                        Refuse (Value_Problem (Stem, US.To_String (Written)));
                     end if;
                  elsif Written = "" then
                     Refuse (Value_Problem (Stem, ""));
                  end if;
                  if Stem = Shared_Color then
                     if Seen_Color then
                        Refuse (Stem & " may be given once");
                     end if;
                     Seen_Color := True;
                     Result.Color := Written;
                  elsif Stem = Shared_Diagnostics then
                     if Seen_Diagnostics then
                        Refuse (Stem & " may be given once");
                     end if;
                     Seen_Diagnostics := True;
                     Result.Style :=
                       (if Written = "json" then Presentation.JSON
                        elsif Written = "short" then Presentation.Short
                        else Presentation.Human);
                  else
                     if Given (Result, Position)
                       and then not Options
                         (Options'First + Position - 1).Repeatable
                     then
                        Refuse (Stem & " may be given once");
                     end if;
                     Result.Values (Position).Append (US.To_String (Written));
                  end if;
               elsif Equal /= 0 then
                  Refuse ("option takes no value: " & Stem);
               elsif Stem = Shared_Help then
                  Result.Wanted := Help;
               elsif Stem = Shared_Verbose then
                  Result.Verbosity := Result.Verbosity + 1;
               elsif Stem = Shared_Quiet then
                  Result.Quiet := True;
               else
                  if Given (Result, Position)
                    and then not Options
                      (Options'First + Position - 1).Repeatable
                  then
                     Refuse (Stem & " may be given once");
                  end if;
                  Result.Values (Position).Append ("");
               end if;
            else
               if Text = "" then
                  Refuse ("empty operand");
               end if;
               Result.Operands.Append (Text);
            end if;
         end;
         Index := Index + 1;
      end loop;
      if Result.Quiet and then Result.Verbosity /= 0 then
         Refuse ("--quiet and --verbose cannot be combined");
      end if;
      return Result;
   end Parse;

   function Usage (About : Command; Options : Option_Array) return String is
      Text : US.Unbounded_String;
      procedure Line (Spelling, Description : String);
      procedure Line (Spelling, Description : String) is
      begin
         US.Append (Text, "  " & Spelling
           & Ada.Strings.Fixed."*"
               (Natural'Max (1, 26 - Spelling'Length), ' ')
           & Description & LF);
      end Line;
   begin
      US.Append (Text, "usage: refine " & US.To_String (About.Name) & " "
        & US.To_String (About.Usage) & LF & LF
        & US.To_String (About.Summary) & LF & LF & "Options:" & LF);
      Line ("-h, --help", "Print this command's help and exit");
      Line ("-v, --verbose", "Accepted as every command takes it; adds"
        & " nothing here");
      Line ("-q, --quiet", "Suppress progress, retaining warnings and errors");
      Line ("--color VALUE",
            "Diagnostic color: auto (default), always, never");
      Line ("--diagnostics VALUE",
            "Diagnostic format on standard error: human (default), short,"
            & " json");
      for Item of Options loop
         Line (US.To_String (Item.Name)
                 & (if US.Length (Item.Value_Name) = 0 then ""
                    else " " & US.To_String (Item.Value_Name)),
               US.To_String (Item.Description));
      end loop;
      US.Append (Text, LF
        & "Options follow the command's name. Values may use a space or"
        & LF & "'='. Use '--' before literal operands; @FILE reads a"
        & " response" & LF & "file. Single-valued options may be given once."
        & LF & "refine " & US.To_String (About.Name) & " runs refine-"
        & US.To_String (About.Name)
        & ", shipped beside refine and built from" & LF
        & "the same sources." & LF);
      if US.Length (About.Notes) > 0 then
         US.Append (Text, LF & US.To_String (About.Notes));
      end if;
      return US.To_String (Text);
   end Usage;

   function Description (About : Command) return String is
     ("{""format"":""landin-command-1"",""name"":"
      & J.Quoted (US.To_String (About.Name))
      & ",""summary"":" & J.Quoted (US.To_String (About.Summary))
      & ",""source_digest"":" & J.Quoted (Landin.Build_Identity.Source_Digest)
      & ",""codes"":[]}" & LF);

   function Completion
     (Options : Option_Array; Words : Landin.Platform.Path_List)
      return String
   is
      Text : US.Unbounded_String;
      Last : constant String :=
        (if Words.Is_Empty then "" else Words.Last_Element);
      Before : constant String :=
        (if Natural (Words.Length) < 2 then ""
         else Words (Natural (Words.Length) - 1));
      procedure Offer (Candidate : String);
      procedure Offer (Candidate : String) is
      begin
         if Candidate'Length >= Last'Length
           and then Candidate
             (Candidate'First .. Candidate'First + Last'Length - 1) = Last
         then
            US.Append (Text, Candidate & LF);
         end if;
      end Offer;
      procedure Offer_Choices (Prefix, Listed : String);
      procedure Offer_Choices (Prefix, Listed : String) is
         First : Positive := Listed'First;
      begin
         for Index in Listed'First .. Listed'Last + 1 loop
            if Index > Listed'Last or else Listed (Index) = '|' then
               Offer (Prefix & Listed (First .. Index - 1));
               First := Index + 1;
            end if;
         end loop;
      end Offer_Choices;
   begin
      --  A value of a shared option with choices, after it or its `=`.
      if Before in Shared_Color | Shared_Diagnostics then
         Offer_Choices ("", Choices (Before));
      elsif Last'Length > 0 and then Last (Last'First) = '-' then
         if Ada.Strings.Fixed.Index (Last, "=") /= 0 then
            declare
               Stem : constant String :=
                 Last (Last'First .. Ada.Strings.Fixed.Index (Last, "=") - 1);
            begin
               if Choices (Stem) /= "" then
                  Offer_Choices (Stem & "=", Choices (Stem));
               end if;
            end;
         else
            for Name of Shared_Names loop
               Offer (Name.all);
               if Name.all = Shared_Help then
                  Offer ("-h");
               elsif Name.all = Shared_Verbose then
                  Offer ("-v");
               elsif Name.all = Shared_Quiet then
                  Offer ("-q");
               end if;
            end loop;
            for Item of Options loop
               Offer (US.To_String (Item.Name));
            end loop;
         end if;
      end if;
      --  Anything else is a path, which the shell completes itself.
      return US.To_String (Text);
   end Completion;

   function Refused
     (Code    : Landin.Diagnostics.Catalogue.Code_Name;
      Message : String;
      Status  : Natural) return Landin.Outcomes.Outcome
   is
      Result : Landin.Outcomes.Outcome;
      None : Landin.Source.Sets.Source_Set;
   begin
      Result.Status := Status;
      Result.Found.Append
        (Landin.Diagnostics.Make
           (Code => Landin.Diagnostics.Catalogue.Code (Code),
            Level => Landin.Diagnostics.Error,
            Source => Landin.Source.No_Source,
            Where => Landin.Source.Empty_Span, Message => Message));
      Result.Report := US.To_Unbounded_String
        (Landin.Diagnostics.Text.Render (Result.Found, None));
      return Result;
   end Refused;

   function Execute
     (About     : Command;
      Options   : Option_Array;
      Perform   : Runner;
      Arguments : Landin.Platform.Path_List;
      Host      : Landin.Platform.Filesystem'Class;
      Tools     : Landin.Platform.Tool_Runner'Class;
      Built_For : String;
      Terminal_Color : Boolean := False) return Landin.Outcomes.Outcome
   is
      Asked : constant Request := Parse (Options, Arguments, Host);
      Result : Landin.Outcomes.Outcome;
   begin
      if US.Length (Asked.Problem) /= 0 then
         Result := Refused
           (Landin.Diagnostics.Catalogue.Unknown_Option,
            US.To_String (Asked.Problem), Landin.Outcomes.Status_Misuse);
      else
         case Asked.Wanted is
            when Describe =>
               Result.Output := US.To_Unbounded_String (Description (About));
               return Result;
            when Complete =>
               Result.Output := US.To_Unbounded_String
                 (Completion (Options, Asked.Completed));
               return Result;
            when Help =>
               Result.Output := US.To_Unbounded_String
                 (Usage (About, Options));
            when Run =>
               Result := Perform (Asked, Host, Tools, Built_For);
         end case;
      end if;
      Presentation.Render
        (Result, Asked.Style,
         US.To_String (Asked.Color) = "always"
         or else (US.To_String (Asked.Color) = "auto" and Terminal_Color));
      return Result;
   end Execute;

end Landin.Splits;
