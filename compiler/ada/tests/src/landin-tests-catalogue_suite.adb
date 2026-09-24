--  The catalogue, and the diagnostics raised against it.
--
--  The catalogue's evidence is that a negative case asserts code and spans
--  separately from prose, and that rendering has focused golden tests.
--  These cases do the first; the golden is the last one.

with Landin.Diagnostics.Catalogue;
with Landin.Diagnostics.Lexical;
with Landin.Diagnostics.Text;
with Landin.Diagnostics;
with Landin.Source.Names;
with Landin.Source.Sets;
with Landin.Source;
with Landin.Tokens.Lexer;
with Landin.Tokens;

package body Landin.Tests.Catalogue_Suite is

   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.Diagnostics.Severity;
   use type Rows.Code_Name;
   use type Rows.Disposition;
   use type Landin.Source.Byte_Offset;

   LF : constant Character := Character'Val (10);

   procedure Lex_And_Report
     (Text    : String;
      Sources : in out Landin.Source.Sets.Source_Set;
      Report  : in out Landin.Diagnostics.Diagnostic_List);

   procedure Lex_And_Report
     (Text    : String;
      Sources : in out Landin.Source.Sets.Source_Set;
      Report  : in out Landin.Diagnostics.Diagnostic_List)
   is
      Names  : Landin.Source.Names.Table;
      Stream : Landin.Tokens.Token_Stream;
      Id     : constant Landin.Source.Source_Id :=
        Sources.Add ("case.ldn", Text);
   begin
      Landin.Tokens.Lexer.Lex (Sources.Get (Id), Names, Stream);
      Landin.Diagnostics.Lexical.Report (Stream, Report);
   end Lex_And_Report;

   --  Every row is complete and every code is its own.
   procedure Rows_Are_Whole (Item : in out Landin.Testing.Context);

   procedure Rows_Are_Whole (Item : in out Landin.Testing.Context) is
   begin
      for Name in Rows.Code_Name loop
         Landin.Testing.Check
           (Item, Landin.Diagnostics.Is_Valid_Code (Rows.Code (Name)),
            Name'Image & " has a well-formed code");
         Landin.Testing.Check
           (Item, Rows.Rule (Name)'Length > 10,
            Name'Image & " says which rule it enforces");
         Landin.Testing.Check
           (Item, Rows.Named (Rows.Code (Name)) = Name,
            Name'Image & " is found by its own code");
         Landin.Testing.Check
           (Item, Rows.Minimum_Secondaries (Name)
                    <= Rows.Maximum_Secondaries (Name),
            Name'Image & " has a valid secondary-label interval");
         if Name not in Rows.Literal_Out_Of_Range
                      | Rows.Impossible_Operand
                      | Rows.Unsupported_Use
                      | Rows.Not_Known_At_Compile_Time
         then
            Landin.Testing.Check_Equal
              (Item, Rows.Minimum_Secondaries (Name),
               Rows.Maximum_Secondaries (Name),
               Name'Image & " retains one exact secondary-label count");
         end if;
      end loop;

      Landin.Testing.Check
        (Item,
         Rows.Minimum_Secondaries (Rows.Literal_Out_Of_Range) = 0
           and then Rows.Maximum_Secondaries
             (Rows.Literal_Out_Of_Range) = 1
           and then Rows.Minimum_Secondaries (Rows.Impossible_Operand) = 0
           and then Rows.Maximum_Secondaries (Rows.Impossible_Operand) = 1
           and then Rows.Minimum_Secondaries (Rows.Unsupported_Use) = 0
           and then Rows.Maximum_Secondaries (Rows.Unsupported_Use) = 1,
         "dependent checker reports admit one template label");

      --  Distinct, because a number that names two rules is worse than no
      --  number at all.
      for Left in Rows.Code_Name loop
         for Right in Rows.Code_Name loop
            if Left /= Right then
               Landin.Testing.Check
                 (Item, Rows.Code (Left) /= Rows.Code (Right),
                  "no two rows share a code");
            end if;
         end loop;
      end loop;

      Landin.Testing.Check_Equal
        (Item, Rows.Count, 61, "the catalogue holds sixty-one codes");
   end Rows_Are_Whole;

   --  A fault kind maps to exactly one code, and every kind has one.
   procedure Every_Fault_Has_A_Code (Item : in out Landin.Testing.Context);

   procedure Every_Fault_Has_A_Code (Item : in out Landin.Testing.Context) is
   begin
      for Kind in Landin.Tokens.Fault_Kind loop
         declare
            Named : constant Rows.Code_Name :=
              Landin.Diagnostics.Lexical.Code_For (Kind);
         begin
            Landin.Testing.Check
              (Item, Rows.State (Named) = Rows.Live,
               Kind'Image & " raises a live code");
            Landin.Testing.Check
              (Item, Rows.Level (Named) = Landin.Diagnostics.Error,
               Kind'Image & " is an error");
         end;
      end loop;
   end Every_Fault_Has_A_Code;

   --  Code and spans, asserted without a word of the prose.
   procedure Codes_And_Spans_Without_Prose
     (Item : in out Landin.Testing.Context);

   procedure Codes_And_Spans_Without_Prose
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Report  : Landin.Diagnostics.Diagnostic_List;
   begin
      --  A malformed hexadecimal exponent is one fault over the whole
      --  lexeme rather than a fault at only its trailing sign.
      Lex_And_Report ("r: f64 = 0x1.0p+", Sources, Report);

      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Count (Report), 1, "one diagnostic");
      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Code (Landin.Diagnostics.Get (Report, 1)),
         Rows.Code (Rows.Malformed_Float_Literal),
         "the malformed exponent carries the catalogue's code");
      Landin.Testing.Check
        (Item,
         Landin.Diagnostics.Span_Of
           (Landin.Diagnostics.Primary
              (Landin.Diagnostics.Get (Report, 1))).First = 9,
         "and the span starts at the lexeme");
      Landin.Testing.Check
        (Item,
         Landin.Diagnostics.Span_Of
           (Landin.Diagnostics.Primary
           (Landin.Diagnostics.Get (Report, 1))).Last = 16,
         "and ends at the end of it, not at the exponent marker");
      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Note_Count
           (Landin.Diagnostics.Get (Report, 1)),
         Rows.Required_Notes (Rows.Malformed_Float_Literal),
         "and carries the notes its row requires");
   end Codes_And_Spans_Without_Prose;

   --  [1780]'s unterminated comment points at two places, and the row says
   --  it must.
   procedure Unterminated_Points_At_Both
     (Item : in out Landin.Testing.Context);

   procedure Unterminated_Points_At_Both
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Report  : Landin.Diagnostics.Diagnostic_List;
   begin
      Lex_And_Report ("--( never closed", Sources, Report);

      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Code (Landin.Diagnostics.Get (Report, 1)),
         Rows.Code (Rows.Unterminated_Comment), "the comment's own code");
      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Label_Count
           (Landin.Diagnostics.Get (Report, 1)),
         Rows.Minimum_Secondaries (Rows.Unterminated_Comment),
         "and the secondary label its row requires");
      Landin.Testing.Check
        (Item,
         Landin.Diagnostics.Span_Of
           (Landin.Diagnostics.Nth_Label
              (Landin.Diagnostics.Get (Report, 1), 1)).First = 0,
         "which points at the opener");
   end Unterminated_Points_At_Both;

   --  The one golden: what a user actually sees.
   procedure Rendering_Is_Golden (Item : in out Landin.Testing.Context);

   procedure Rendering_Is_Golden (Item : in out Landin.Testing.Context) is
      Sources : Landin.Source.Sets.Source_Set;
      Report  : Landin.Diagnostics.Diagnostic_List;

      Expected : constant String :=
        "error[L0321]: this is not a well-formed floating-point literal" & LF
        & "  --> case.ldn:1:10" & LF
        & "  |" & LF
        & "1 | r: f64 = 0x1.0p+" & LF
        & "  |          ^^^^^^^" & LF
        & "  = note: a float has digits on both sides of its dot and a"
        & " complete exponent when one is required [0210] [0220] [0230]"
        & LF;
   begin
      Lex_And_Report ("r: f64 = 0x1.0p+", Sources, Report);

      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Render (Report, Sources), Expected,
         "a malformed float renders exactly with its lexical rule");
   end Rendering_Is_Golden;

   procedure Uppercase_And_Mixed_Bytes_Have_Exact_Reports
     (Item : in out Landin.Testing.Context);

   procedure Uppercase_And_Mixed_Bytes_Have_Exact_Reports
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Report  : Landin.Diagnostics.Diagnostic_List;
      Expected : constant String :=
        "error[L0012]: identifiers use lower-case letters" & LF
        & "  --> case.ldn:1:1" & LF
        & "  |" & LF
        & "1 | ABC A;B" & LF
        & "  | ^^^" & LF
        & "  = note: [1760]: identifier letters are lower-case ASCII" & LF
        & "error[L0012]: no rule spells these bytes" & LF
        & "  --> case.ldn:1:5" & LF
        & "  |" & LF
        & "1 | ABC A;B" & LF
        & "  |     ^^^" & LF
        & "  = note: no rule of the grammar spells these bytes [1750]" & LF;
   begin
      Lex_And_Report ("ABC A;B", Sources, Report);
      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Render (Report, Sources), Expected,
         "uppercase and mixed runs keep their code, span and explanation");
   end Uppercase_And_Mixed_Bytes_Have_Exact_Reports;

   procedure Integer_Guidance_Covers_Missing_Digits
     (Item : in out Landin.Testing.Context);

   procedure Integer_Guidance_Covers_Missing_Digits
     (Item : in out Landin.Testing.Context)
   is
      procedure Check (Text : String; Accepted : Boolean := False);

      procedure Check (Text : String; Accepted : Boolean := False) is
         Sources : Landin.Source.Sets.Source_Set;
         Reports : Landin.Diagnostics.Diagnostic_List;
      begin
         Lex_And_Report (Text, Sources, Reports);
         Landin.Testing.Check_Equal
           (Item, Landin.Diagnostics.Count (Reports),
            (if Accepted then 0 else 1), Text & " has its exact verdict");
         if not Accepted and then Landin.Diagnostics.Count (Reports) = 1 then
            declare
               Report : constant Landin.Diagnostics.Diagnostic :=
                 Landin.Diagnostics.Get (Reports, 1);
               Where : constant Landin.Source.Span :=
                 Landin.Diagnostics.Span_Of
                   (Landin.Diagnostics.Primary (Report));
            begin
               Landin.Testing.Check
                 (Item, Landin.Diagnostics.Code (Report) = "L0011"
                  and then Where.First = 0
                  and then Where.Last = Landin.Source.Byte_Offset
                    (Text'Length),
                  Text & " keeps its malformed-integer code and whole run");
               Landin.Testing.Check
                 (Item, Landin.Diagnostics.Note_Count (Report) = 1
                  and then Landin.Diagnostics.Nth_Note (Report, 1) =
                    "use digits of the selected base and underscores; start"
                    & " and end the digit run with a digit [1770]",
                  Text & " names the complete digit-run requirements");
            end;
         end if;
      end Check;
   begin
      Check ("0x");
      Check ("0b");
      Check ("1_");
      Check ("0o7_");
      Check ("0b102");
      Check ("12a");
      Check ("0x_FF");
      Check ("1__0", Accepted => True);
      Check ("0xDEAD_BEEF", Accepted => True);
      --  D245: the letter belongs to the number, and a space ends it.
      Check ("12z");
      Check ("1u64");
      Check ("12 z", Accepted => True);
   end Integer_Guidance_Covers_Missing_Digits;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "catalogue", "integer guidance covers missing digits",
         Integer_Guidance_Covers_Missing_Digits'Access);
      Landin.Testing.Register
        (Into, "catalogue", "rows are whole", Rows_Are_Whole'Access);
      Landin.Testing.Register
        (Into, "catalogue", "every fault has a code",
         Every_Fault_Has_A_Code'Access);
      Landin.Testing.Register
        (Into, "catalogue", "codes and spans without prose",
         Codes_And_Spans_Without_Prose'Access);
      Landin.Testing.Register
        (Into, "catalogue", "unterminated points at both",
         Unterminated_Points_At_Both'Access);
      Landin.Testing.Register
        (Into, "catalogue", "rendering is golden",
         Rendering_Is_Golden'Access);
      Landin.Testing.Register
        (Into, "catalogue", "uppercase and mixed bytes have exact reports",
         Uppercase_And_Mixed_Bytes_Have_Exact_Reports'Access);
   end Register;

end Landin.Tests.Catalogue_Suite;
