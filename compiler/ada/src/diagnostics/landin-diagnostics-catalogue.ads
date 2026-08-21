--  The diagnostic catalogue.
--
--  Every code the compiler can raise has a row here, and this is the only
--  place in `src/` where a code is written. A code with no row does not
--  compile: each column is an exhaustive case over Code_Name, so leaving one
--  out is a missing-case error rather than a warning.
--
--  Prose is deliberately absent. `L0003` is raised with two sentences today
--  -- a source that is missing and one that is unreadable -- because one
--  rule was violated and the difference between the two is wording. A table
--  of messages would either lie about that or split a code for a wording
--  reason, which is the worst reason to spend a stable identifier. The exact
--  bytes live in a fixture's golden; what a code requires of every one of
--  its occurrences lives here.
--
--  A code is a name, not an address. The bands below record where a code was
--  born, not which stage owns it: `L0010` is raised by the scanner today and
--  by the parser at R1.40. A retired code keeps its row, so its number can
--  never be handed to a different rule -- that is how "codes remain stable"
--  becomes a fact in a file rather than a promise in a paragraph.
--
--     L0001-L0009  the driver and the chassis
--     L0010-L0099  lexical, and the refusal of what is not enabled
--     L0100-L0199  reserved for R1.40's syntax failures
--     L0200-L0299  reserved for R1.50's name failures
--     L0300-L0399  reserved for R1.60's type failures

package Landin.Diagnostics.Catalogue is

   type Code_Name is
     (
      --  The driver, assigned at R0.50 because a driver that cannot
      --  explain itself cannot be tested.
      No_Frontend,
      Unknown_Option,
      Unreadable_Source,
      Unknown_Target,
      --  The scanner, assigned at R1.30.
      Construct_Not_Enabled,
      Malformed_Integer,
      Unknown_Bytes,
      Unterminated_Comment,
      Unterminated_Literal);

   --  Live, or kept so its number is never reused. A code is retired when
   --  the rule it names stops existing: `No_Frontend` retires when the
   --  frontend is wired to the driver.
   type Disposition is (Live, Retired);

   function Code (Of_Code : Code_Name) return Code_String
     is (case Of_Code is
            when No_Frontend           => "L0001",
            when Unknown_Option        => "L0002",
            when Unreadable_Source     => "L0003",
            when Unknown_Target        => "L0004",
            when Construct_Not_Enabled => "L0010",
            when Malformed_Integer     => "L0011",
            when Unknown_Bytes         => "L0012",
            when Unterminated_Comment  => "L0013",
            when Unterminated_Literal  => "L0014");

   function Level (Of_Code : Code_Name) return Severity
     is (case Of_Code is
            when No_Frontend           => Error,
            when Unknown_Option        => Error,
            when Unreadable_Source     => Error,
            when Unknown_Target        => Error,
            when Construct_Not_Enabled => Error,
            when Malformed_Integer     => Error,
            when Unknown_Bytes         => Error,
            when Unterminated_Comment  => Error,
            when Unterminated_Literal  => Error);

   function State (Of_Code : Code_Name) return Disposition
     is (case Of_Code is
            when No_Frontend           => Live,
            when Unknown_Option        => Live,
            when Unreadable_Source     => Live,
            when Unknown_Target        => Live,
            when Construct_Not_Enabled => Live,
            when Malformed_Integer     => Live,
            when Unknown_Bytes         => Live,
            when Unterminated_Comment  => Live,
            when Unterminated_Literal  => Live);

   --  The rule the code enforces, in one line. Documentation, not prose a
   --  user reads: the message at the raise site is what a user reads.
   function Rule (Of_Code : Code_Name) return String
     is (case Of_Code is
            when No_Frontend           =>
               "a source was read and no frontend is wired to the driver",
            when Unknown_Option        =>
               "an option the driver does not define",
            when Unreadable_Source     =>
               "a source that is missing or cannot be read",
            when Unknown_Target        =>
               "a target no description names",
            when Construct_Not_Enabled =>
               "[1830]: the tour describes this and the kernel omits it",
            when Malformed_Integer     =>
               "[1770]: a digit outside the base the prefix selected",
            when Unknown_Bytes         =>
               "[1750]: a run of bytes no rule spells",
            when Unterminated_Comment  =>
               "[1780]: a block comment that is never closed",
            when Unterminated_Literal  =>
               "[0260]: a quoted literal that is never closed");

   ------------------------------------------------------------------
   --  What every occurrence of a code must carry
   --
   --  The row states the shape; the fixture states where. Both are checked,
   --  and neither is prose.
   ------------------------------------------------------------------

   --  Whether the diagnostic must name a source. The driver's own codes
   --  are raised before any file is read, so they must not.
   function Needs_Source (Of_Code : Code_Name) return Boolean
     is (case Of_Code is
            when No_Frontend           => True,
            when Unknown_Option        => False,
            when Unreadable_Source     => False,
            when Unknown_Target        => False,
            when Construct_Not_Enabled => True,
            when Malformed_Integer     => True,
            when Unknown_Bytes         => True,
            when Unterminated_Comment  => True,
            when Unterminated_Literal  => True);

   --  Whether the primary span must cover at least one byte. An empty span
   --  points between two bytes, which is right for a missing token and
   --  wrong for a lexeme that is present and refused.
   function Needs_Non_Empty_Span (Of_Code : Code_Name) return Boolean
     is (case Of_Code is
            when No_Frontend           => False,
            when Unknown_Option        => False,
            when Unreadable_Source     => False,
            when Unknown_Target        => False,
            when Construct_Not_Enabled => True,
            when Malformed_Integer     => True,
            when Unknown_Bytes         => True,
            when Unterminated_Comment  => False,
            when Unterminated_Literal  => True);

   --  How many secondary labels the diagnostic must carry. An unterminated
   --  block comment needs one: the end of the file is where it was noticed
   --  and the opener is where it went wrong, and a reader looks at both.
   function Required_Secondaries (Of_Code : Code_Name) return Natural
     is (case Of_Code is
            when Unterminated_Comment  => 1,
            when Unterminated_Literal  => 1,
            when others                => 0);

   --  How many notes. [1830] promises a diagnostic that names the construct
   --  and says which work enables it, which is two facts and so two notes.
   function Required_Notes (Of_Code : Code_Name) return Natural
     is (case Of_Code is
            when No_Frontend           => 1,
            when Construct_Not_Enabled => 2,
            when Malformed_Integer     => 1,
            when Unknown_Bytes         => 1,
            when others                => 0);

   function Count return Natural
     is (Code_Name'Pos (Code_Name'Last) - Code_Name'Pos (Code_Name'First) + 1);

   --  Which name a code string belongs to, for a test that starts from the
   --  number. Raises Compiler_Defect on a code no row holds, because a code
   --  outside the catalogue is the defect this package exists to prevent.
   function Named (Text : Code_String) return Code_Name;

end Landin.Diagnostics.Catalogue;
