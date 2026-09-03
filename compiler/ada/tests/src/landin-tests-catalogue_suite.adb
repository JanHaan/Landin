--  The catalogue, and the diagnostics raised against it.
--
--  R1.30's exit evidence is that a negative case asserts code and spans
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
        (Item, Rows.Count, 55, "the catalogue holds fifty-five codes");
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
      --  A hexadecimal float is refused by [1830], and the span is the
      --  whole lexeme
      --  rather than the dot inside it.
      Lex_And_Report ("r: f64 = 0x1.0p0", Sources, Report);

      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Count (Report), 1, "one diagnostic");
      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Code (Landin.Diagnostics.Get (Report, 1)),
         Rows.Code (Rows.Construct_Not_Enabled),
         "the refusal carries the catalogue's code");
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
         "and ends at the end of it, not at the dot");
      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Note_Count
           (Landin.Diagnostics.Get (Report, 1)),
         Rows.Required_Notes (Rows.Construct_Not_Enabled),
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
        "error[L0010]: this construct is not enabled yet" & LF
        & "  --> case.ldn:1:10" & LF
        & "  |" & LF
        & "1 | r: f64 = 0x1.0p0" & LF
        & "  |          ^^^^^^^" & LF
        & "  = note: the tour describes it at [0230]" & LF
        & "  = note: ROADMAP.md R4.10 is where it is enabled" & LF;
   begin
      Lex_And_Report ("r: f64 = 0x1.0p0", Sources, Report);

      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Render (Report, Sources), Expected,
         "a refusal renders exactly, and names the construct and the work");
   end Rendering_Is_Golden;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
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
   end Register;

end Landin.Tests.Catalogue_Suite;
