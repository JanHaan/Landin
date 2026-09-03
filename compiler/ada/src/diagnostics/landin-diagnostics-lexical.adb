with Landin.Source;

package body Landin.Diagnostics.Lexical is

   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.Source.Byte_Offset;
   use type Landin.Tokens.Fault_Kind;

   --  The sentence a user reads.  Prose lives where a diagnostic is
   --  raised, never in the catalogue: one rule can be violated in two ways
   --  worth wording differently, and splitting a code for a wording reason
   --  is the worst reason to spend a stable identifier.
   function Sentence (Fault : Landin.Tokens.Fault) return String;

   function Sentence (Fault : Landin.Tokens.Fault) return String
     is (case Landin.Tokens.Kind (Fault) is
            when Landin.Tokens.Not_Enabled =>
               "this construct is not enabled yet",
            when Landin.Tokens.Malformed_Integer_Run =>
               "this is not an integer any base spells",
            when Landin.Tokens.Malformed_Float_Literal_Run =>
               "this is not a well-formed floating-point literal",
            when Landin.Tokens.Malformed_Character_Literal_Run =>
               "this character literal does not spell one codepoint",
            when Landin.Tokens.Malformed_Raw_Literal_Run =>
               "this raw literal has invalid source bytes or indentation",
            when Landin.Tokens.Malformed_Text_Literal_Run =>
               "this text literal contains malformed bytes or an escape",
            when Landin.Tokens.Unknown_Byte_Run =>
               "no rule spells these bytes",
            when Landin.Tokens.Unterminated_Block_Comment =>
               "this block comment is never closed",
            when Landin.Tokens.Unterminated_Literal =>
               "this literal is never closed");

   function Code_For (Fault : Landin.Tokens.Fault_Kind)
     return Rows.Code_Name
     is (case Fault is
            when Landin.Tokens.Not_Enabled                =>
               Rows.Construct_Not_Enabled,
            when Landin.Tokens.Malformed_Integer_Run      =>
               Rows.Malformed_Integer,
            when Landin.Tokens.Malformed_Float_Literal_Run =>
               Rows.Malformed_Float_Literal,
            when Landin.Tokens.Malformed_Character_Literal_Run =>
               Rows.Malformed_Character_Literal,
            when Landin.Tokens.Malformed_Raw_Literal_Run =>
               Rows.Malformed_Raw_Literal,
            when Landin.Tokens.Malformed_Text_Literal_Run =>
               Rows.Malformed_Text_Literal,
            when Landin.Tokens.Unknown_Byte_Run           =>
               Rows.Unknown_Bytes,
            when Landin.Tokens.Unterminated_Block_Comment =>
               Rows.Unterminated_Comment,
            when Landin.Tokens.Unterminated_Literal       =>
               Rows.Unterminated_Literal);

   function Enabled_By (Refused : Landin.Tokens.Deferred_Kind) return String
     is (case Refused is
            when Landin.Tokens.Hex_Float_Literal => "R4.10",
            when Landin.Tokens.Compound_Assign  => "R4.10");

   procedure Report
     (Stream : Landin.Tokens.Token_Stream;
      Into   : in out Diagnostic_List)
   is
      Source : constant Landin.Source.Source_Id :=
        Landin.Tokens.Source_Of (Stream);
   begin
      for Index in 1 .. Landin.Tokens.Fault_Count (Stream) loop
         declare
            Fault : constant Landin.Tokens.Fault :=
              Landin.Tokens.Nth_Fault (Stream, Index);
            Kind  : constant Landin.Tokens.Fault_Kind :=
              Landin.Tokens.Kind (Fault);
            Named : constant Rows.Code_Name := Code_For (Kind);
            Where : constant Landin.Source.Span :=
              Landin.Tokens.Where (Fault);
            Text  : constant Code_String := Rows.Code (Named);
            Report : Diagnostic :=
              Make (Code    => Text,
                    Level   => Rows.Level (Named),
                    Source  => Source,
                    Where   => Where,
                    Message => Sentence (Fault));
         begin
            case Kind is
               when Landin.Tokens.Not_Enabled =>
                  Add_Note
                    (Report,
                     "the tour describes it at "
                     & Landin.Tokens.Construct
                         (Landin.Tokens.Refused (Fault)));
                  Add_Note
                    (Report,
                     "ROADMAP.md "
                     & Enabled_By
                         (Landin.Tokens.Deferred_Kind
                            (Landin.Tokens.Refused (Fault)))
                     & " is where it is enabled");

               when Landin.Tokens.Unterminated_Literal =>
                  Add_Label
                    (Report,
                     Make_Label (Source,
                                 Landin.Tokens.Opened_At (Fault),
                                 "opened here"));

               when Landin.Tokens.Unterminated_Block_Comment =>
                  Add_Label
                    (Report,
                     Make_Label (Source,
                                 Landin.Tokens.Opened_At (Fault),
                                 "opened here and never closed"));

               when Landin.Tokens.Malformed_Integer_Run =>
                  Add_Note
                    (Report,
                     "a digit outside the base its prefix selected [1770]");

               when Landin.Tokens.Malformed_Float_Literal_Run =>
                  Add_Note
                    (Report,
                     "a decimal float has digits on both sides of its dot"
                     & " and a complete optional exponent [0210] [0220]");

               when Landin.Tokens.Malformed_Character_Literal_Run =>
                  Add_Note
                    (Report,
                     "write one source scalar, a simple escape, or"
                     & " `\\u{...}` [0250] [0270]");

               when Landin.Tokens.Malformed_Raw_Literal_Run =>
                  Add_Note
                    (Report,
                     "use matching quote counts and the exact indentation"
                     & " of a line-leading closer [0280]");

               when Landin.Tokens.Malformed_Text_Literal_Run =>
                  Add_Note
                    (Report,
                     "the text escape set is closed and small [0270]");

               when Landin.Tokens.Unknown_Byte_Run =>
                  Add_Note
                    (Report,
                     "no rule of the grammar spells these bytes [1750]");
            end case;

            --  The row this code carries is checked against the diagnostic
            --  just built.  A code whose occurrences do not carry what it
            --  promises is worse than no code at all.
            if Rows.Required_Notes (Named) /= Note_Count (Report)
              or else Label_Count (Report)
                      < Rows.Minimum_Secondaries (Named)
              or else Label_Count (Report)
                      > Rows.Maximum_Secondaries (Named)
            then
               raise Compiler_Defect
                 with "the catalogue row for " & Text
                      & " and the diagnostic built for it disagree";
            end if;

            if Rows.Needs_Non_Empty_Span (Named)
              and then Landin.Source.Length (Where) = 0
            then
               raise Compiler_Defect
                 with Text & " requires a span with bytes in it";
            end if;

            Append (Into, Report);
         end;
      end loop;
   end Report;

end Landin.Diagnostics.Lexical;
