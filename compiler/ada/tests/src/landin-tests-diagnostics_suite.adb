with Landin.Diagnostics.Text;
with Landin.Source.Sets;

package body Landin.Tests.Diagnostics_Suite is

   use Landin.Diagnostics;

   LF : constant Character := Character'Val (10);

   procedure Codes_Are_Validated (Item : in out Landin.Testing.Context);

   procedure Codes_Are_Validated (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check (Item, Is_Valid_Code ("L0001"), "L0001 is a code");
      Landin.Testing.Check
        (Item, not Is_Valid_Code ("L001"), "four characters is not a code");
      Landin.Testing.Check
        (Item, not Is_Valid_Code ("X0001"), "the prefix must be L");
      Landin.Testing.Check
        (Item, not Is_Valid_Code ("L00A1"), "the digits must be digits");
      Landin.Testing.Check
        (Item, not Is_Valid_Code ("L 001"), "a space is not a digit");
      Landin.Testing.Check
        (Item, not Is_Valid_Code ("l0001"), "the prefix is upper case");
      Landin.Testing.Check
        (Item, not Is_Valid_Code (""), "an empty string is not a code");
      Landin.Testing.Check
        (Item, not Is_Valid_Code ("L00011"), "six characters is not a code");
      Landin.Testing.Check
        (Item, Is_Valid_Code ("L0000") and then Is_Valid_Code ("L9999"),
         "every four-digit number is a code");

      --  Each digit position in turn, because a check that only looked at
      --  the last one would pass everything above.
      for Position in 2 .. 5 loop
         declare
            Broken : String := "L0001";
         begin
            Broken (Position) := 'x';
            Landin.Testing.Check
              (Item, not Is_Valid_Code (Broken),
               "position" & Integer'Image (Position) & " must be a digit");
         end;
      end loop;
   end Codes_Are_Validated;

   procedure Labels_And_Notes_Are_Kept
     (Item : in out Landin.Testing.Context);

   procedure Labels_And_Notes_Are_Kept
     (Item : in out Landin.Testing.Context)
   is
      Report : Diagnostic :=
        Make ("L0100", Error, 1, (First => 2, Last => 5), "primary text");
   begin
      Add_Label
        (Report,
         Make_Label (1, (First => 8, Last => 9), "secondary text"));
      Add_Note (Report, "a note");

      Landin.Testing.Check_Equal
        (Item, Code (Report), "L0100", "the code round trips");
      Landin.Testing.Check_Equal
        (Item, Message (Primary (Report)), "primary text", "primary message");
      Landin.Testing.Check_Equal
        (Item, Label_Count (Report), 1, "one secondary label");
      Landin.Testing.Check_Equal
        (Item, Message (Nth_Label (Report, 1)), "secondary text",
         "secondary message");
      Landin.Testing.Check_Equal
        (Item, Note_Count (Report), 1, "one note");
      Landin.Testing.Check_Equal
        (Item, Nth_Note (Report, 1), "a note", "note text");
   end Labels_And_Notes_Are_Kept;

   procedure Order_Is_Independent_Of_Arrival
     (Item : in out Landin.Testing.Context);

   procedure Order_Is_Independent_Of_Arrival
     (Item : in out Landin.Testing.Context)
   is
      Forward  : Diagnostic_List;
      Backward : Diagnostic_List;

      Late  : constant Diagnostic :=
        Make ("L0200", Error, 1, (First => 20, Last => 21), "late");
      Early : constant Diagnostic :=
        Make ("L0100", Warning, 1, (First => 2, Last => 3), "early");
      Other : constant Diagnostic :=
        Make ("L0300", Error, 2, (First => 0, Last => 1), "other file");
   begin
      Forward.Append (Early);
      Forward.Append (Late);
      Forward.Append (Other);

      Backward.Append (Other);
      Backward.Append (Late);
      Backward.Append (Early);

      declare
         Left  : constant Diagnostic_List := Sorted (Forward);
         Right : constant Diagnostic_List := Sorted (Backward);
      begin
         Landin.Testing.Check_Equal
           (Item, Message (Primary (Get (Left, 1))), "early",
            "the earliest span comes first");
         Landin.Testing.Check_Equal
           (Item, Message (Primary (Get (Left, 3))), "other file",
            "a later source comes last");

         for Index in 1 .. Count (Left) loop
            Landin.Testing.Check_Equal
              (Item,
               Message (Primary (Get (Left, Index))),
               Message (Primary (Get (Right, Index))),
               "arrival order does not change the report");
         end loop;
      end;

      Landin.Testing.Check (Item, Has_Errors (Forward), "errors are counted");
      Landin.Testing.Check_Equal
        (Item, Count_Of (Forward, Warning), 1, "warnings are counted");
   end Order_Is_Independent_Of_Arrival;

   procedure Rendering_Is_Stable (Item : in out Landin.Testing.Context);

   procedure Rendering_Is_Stable (Item : in out Landin.Testing.Context) is
      Sources : Landin.Source.Sets.Source_Set;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add ("demo.ldn", "let x = 1" & LF & "let y = 2" & LF);
      Report  : Diagnostic :=
        Make ("L0101", Error, Id, (First => 4, Last => 5), "unexpected name");
      List    : Diagnostic_List;

      Expected : constant String :=
        "error[L0101]: unexpected name" & LF
        & "  --> demo.ldn:1:5" & LF
        & "  |" & LF
        & "1 | let x = 1" & LF
        & "  |     ^" & LF
        & "  = note: names are not enabled yet" & LF;
   begin
      Add_Note (Report, "names are not enabled yet");
      List.Append (Report);

      declare
         Rendered : constant String :=
           Landin.Diagnostics.Text.Render (List, Sources);
      begin
         Landin.Testing.Check_Equal
           (Item,
            Rendered,
            Expected,
            "one diagnostic renders exactly");
      end;
   end Rendering_Is_Stable;

   procedure Multiple_Labels_Render_In_Order
     (Item : in out Landin.Testing.Context);

   procedure Multiple_Labels_Render_In_Order
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      First   : constant Landin.Source.Source_Id :=
        Sources.Add ("one.ldn", "alpha" & LF & "beta" & LF);
      Second  : constant Landin.Source.Source_Id :=
        Sources.Add ("two.ldn", "gamma" & LF);
      Report  : Diagnostic :=
        Make ("L0102", Error, First, (First => 0, Last => 5),
              "two places disagree");
      List    : Diagnostic_List;

      Expected : constant String :=
        "error[L0102]: two places disagree" & LF
        & "  --> one.ldn:1:1" & LF
        & "  |" & LF
        & "1 | alpha" & LF
        & "  | ^^^^^" & LF
        & "  --> one.ldn:2:1" & LF
        & "  |" & LF
        & "2 | beta" & LF
        & "  | ^^^^ and here" & LF
        & "  --> two.ldn:1:1" & LF
        & "  |" & LF
        & "1 | gamma" & LF
        & "  | ^^^^^ and in another file" & LF;
   begin
      Add_Label
        (Report, Make_Label (First, (First => 6, Last => 10), "and here"));
      Add_Label
        (Report,
         Make_Label (Second, (First => 0, Last => 5),
                     "and in another file"));
      List.Append (Report);

      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Text.Render (List, Sources),
         Expected,
         "labels render in the order they were added");
   end Multiple_Labels_Render_In_Order;

   --  Ties on the span are what the last three comparisons in Precedes
   --  exist for.  Without a case that ties, all three can be deleted and
   --  every other diagnostics case still passes.
   procedure Ties_Are_Broken_Deterministically
     (Item : in out Landin.Testing.Context);

   procedure Ties_Are_Broken_Deterministically
     (Item : in out Landin.Testing.Context)
   is
      Tied : constant Landin.Source.Span := (First => 4, Last => 6);

      Warned      : constant Diagnostic :=
        Make ("L0100", Warning, 1, Tied, "aaa");
      Error_Early : constant Diagnostic :=
        Make ("L0100", Error, 1, Tied, "aaa");
      Error_Later : constant Diagnostic :=
        Make ("L0100", Error, 1, Tied, "bbb");
      Error_Coded : constant Diagnostic :=
        Make ("L0200", Error, 1, Tied, "aaa");

      Forward  : Diagnostic_List;
      Backward : Diagnostic_List;
   begin
      Forward.Append (Warned);
      Forward.Append (Error_Coded);
      Forward.Append (Error_Later);
      Forward.Append (Error_Early);

      Backward.Append (Error_Early);
      Backward.Append (Error_Later);
      Backward.Append (Error_Coded);
      Backward.Append (Warned);

      declare
         Left  : constant Diagnostic_List := Sorted (Forward);
         Right : constant Diagnostic_List := Sorted (Backward);
      begin
         --  Severity first: an error outranks a warning on the same bytes.
         Landin.Testing.Check
           (Item, Level (Get (Left, 1)) = Error,
            "an error on the same span comes before a warning");
         Landin.Testing.Check_Equal
           (Item, Code (Get (Left, 1)), "L0100",
            "the lower code comes first");
         Landin.Testing.Check_Equal
           (Item, Message (Primary (Get (Left, 1))), "aaa",
            "the lower message comes first");
         Landin.Testing.Check_Equal
           (Item, Message (Primary (Get (Left, 2))), "bbb",
            "the higher message comes next");
         Landin.Testing.Check_Equal
           (Item, Code (Get (Left, 3)), "L0200",
            "the higher code comes after both messages");
         Landin.Testing.Check
           (Item, Level (Get (Left, 4)) = Warning,
            "the warning comes last");

         for Index in 1 .. Count (Left) loop
            Landin.Testing.Check_Equal
              (Item,
               Landin.Diagnostics.Text.Image (Level (Get (Left, Index)))
               & Code (Get (Left, Index))
               & Message (Primary (Get (Left, Index))),
               Landin.Diagnostics.Text.Image (Level (Get (Right, Index)))
               & Code (Get (Right, Index))
               & Message (Primary (Get (Right, Index))),
               "a tie is resolved the same way whatever the arrival order");
         end loop;
      end;
   end Ties_Are_Broken_Deterministically;

   --  What a user sees before any file is read.  The negative fixture
   --  records these exact bytes, so the renderer and the golden cannot
   --  drift apart unnoticed.
   procedure A_Sourceless_Diagnostic_Says_So
     (Item : in out Landin.Testing.Context);

   procedure A_Sourceless_Diagnostic_Says_So
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      List    : Diagnostic_List;

      Expected : constant String :=
        "error[L0002]: unknown option: --wat" & LF
        & "  --> <unknown source>" & LF;
   begin
      List.Append
        (Make ("L0002", Error, Landin.Source.No_Source,
               Landin.Source.Empty_Span, "unknown option: --wat"));

      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Text.Render (List, Sources),
         Expected,
         "a diagnostic with no source renders without a snippet");
   end A_Sourceless_Diagnostic_Says_So;

   --  A stage can be wrong about a byte.  Rendering must say so rather
   --  than raise while explaining somebody else's mistake.
   procedure An_Impossible_Span_Is_Reported
     (Item : in out Landin.Testing.Context);

   procedure An_Impossible_Span_Is_Reported
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add ("short.ldn", "ab");
      List    : Diagnostic_List;

      Expected : constant String :=
        "error[L0103]: past the end" & LF
        & "  --> short.ldn: <span outside this source>" & LF;
   begin
      List.Append
        (Make ("L0103", Error, Id, (First => 5, Last => 9),
               "past the end"));

      Landin.Testing.Check_Equal
        (Item,
         Landin.Diagnostics.Text.Render (List, Sources),
         Expected,
         "a span outside its source is reported, not raised");
   end An_Impossible_Span_Is_Reported;

   --  Render is specified to report in Sorted order.  Appending in the
   --  wrong order and asserting the rendered text is what holds it to
   --  that; every other rendering case appends in the order it expects.
   procedure Rendering_Sorts_Its_Input
     (Item : in out Landin.Testing.Context);

   procedure Rendering_Sorts_Its_Input
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add ("two.ldn", "ab" & LF & "cd" & LF);
      List    : Diagnostic_List;

      Expected : constant String :=
        "error[L0110]: first byte" & LF
        & "  --> two.ldn:1:1" & LF
        & "  |" & LF
        & "1 | ab" & LF
        & "  | ^" & LF
        & "error[L0111]: later byte" & LF
        & "  --> two.ldn:2:1" & LF
        & "  |" & LF
        & "2 | cd" & LF
        & "  | ^" & LF;
   begin
      --  Appended last first.
      List.Append
        (Make ("L0111", Error, Id, (First => 3, Last => 4), "later byte"));
      List.Append
        (Make ("L0110", Error, Id, (First => 0, Last => 1), "first byte"));

      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Render (List, Sources), Expected,
         "rendering reports in sorted order, not arrival order");
   end Rendering_Sorts_Its_Input;

   --  Two diagnostics that share a start but not an end, and two that share
   --  everything.  The first pins the span-end comparison; the second pins
   --  the arrival-order decoration that makes the sort total.
   procedure Span_Ends_And_Arrival_Order
     (Item : in out Landin.Testing.Context);

   procedure Span_Ends_And_Arrival_Order
     (Item : in out Landin.Testing.Context)
   is
      Short_Span : constant Landin.Source.Span := (First => 4, Last => 5);
      Long_Span  : constant Landin.Source.Span := (First => 4, Last => 9);

      Wide  : constant Diagnostic :=
        Make ("L0120", Error, 1, Long_Span, "wide");
      Tight : constant Diagnostic :=
        Make ("L0120", Error, 1, Short_Span, "tight");

      First_Twin  : constant Diagnostic :=
        Make ("L0121", Error, 1, Short_Span, "identical");
      Second_Twin : constant Diagnostic :=
        Make ("L0121", Error, 1, Short_Span, "identical");

      List : Diagnostic_List;
   begin
      List.Append (Wide);
      List.Append (Tight);

      declare
         Ordered : constant Diagnostic_List := Sorted (List);
      begin
         Landin.Testing.Check_Equal
           (Item, Message (Primary (Get (Ordered, 1))), "tight",
            "the shorter span comes first when both start together");
      end;

      --  A full tie must keep arrival order rather than whatever the sort
      --  happens to do with equal keys.
      declare
         Twins   : Diagnostic_List;
         Ordered : Diagnostic_List;
      begin
         Twins.Append (First_Twin);
         Twins.Append (Second_Twin);
         Twins.Append (Tight);
         Ordered := Sorted (Twins);

         Landin.Testing.Check_Equal
           (Item, Count (Ordered), 3, "nothing is lost in a tie");
         Landin.Testing.Check_Equal
           (Item, Code (Get (Ordered, 1)), "L0120",
            "the lower code still comes first");
         Landin.Testing.Check_Equal
           (Item, Message (Primary (Get (Ordered, 2))), "identical",
            "the tied pair follows");
         Landin.Testing.Check_Equal
           (Item, Message (Primary (Get (Ordered, 3))), "identical",
            "and both of them are still there");
      end;
   end Span_Ends_And_Arrival_Order;

   --  A caret run must stop at the end of its line, and must be at least
   --  one column wide even for an empty span.
   procedure Carets_Stay_On_Their_Line
     (Item : in out Landin.Testing.Context);

   procedure Carets_Stay_On_Their_Line
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      Id      : constant Landin.Source.Source_Id :=
        Sources.Add ("clip.ldn", "abc" & LF & "defgh" & LF);
      Over    : Diagnostic_List;
      Empty   : Diagnostic_List;

      Clipped : constant String :=
        "error[L0130]: runs past the line" & LF
        & "  --> clip.ldn:1:2" & LF
        & "  |" & LF
        & "1 | abc" & LF
        & "  |  ^^" & LF;

      Pointed : constant String :=
        "error[L0131]: between two bytes" & LF
        & "  --> clip.ldn:2:3" & LF
        & "  |" & LF
        & "2 | defgh" & LF
        & "  |   ^" & LF;
   begin
      --  A span from byte 1 to byte 6 covers the rest of line one and part
      --  of line two; the caret run must stop at the line's end.
      Over.Append
        (Make ("L0130", Error, Id, (First => 1, Last => 6),
               "runs past the line"));
      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Render (Over, Sources), Clipped,
         "a caret run stops at the end of its line");

      --  An empty span still gets one caret, because a diagnostic that
      --  points between two bytes has to point somewhere.
      Empty.Append
        (Make ("L0131", Error, Id, (First => 6, Last => 6),
               "between two bytes"));
      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Render (Empty, Sources), Pointed,
         "an empty span still gets one caret");
   end Carets_Stay_On_Their_Line;

   --  Severity words reach the output.  Only "error" was ever rendered by
   --  a test, so the other two spellings were free to be anything.
   procedure Every_Severity_Is_Spelled
     (Item : in out Landin.Testing.Context);

   procedure Every_Severity_Is_Spelled
     (Item : in out Landin.Testing.Context)
   is
      Sources : Landin.Source.Sets.Source_Set;
      List    : Diagnostic_List;

      Expected : constant String :=
        "error[L0140]: an error" & LF
        & "  --> <unknown source>" & LF
        & "warning[L0141]: a warning" & LF
        & "  --> <unknown source>" & LF
        & "note[L0142]: a note" & LF
        & "  --> <unknown source>" & LF;
   begin
      List.Append
        (Make ("L0142", Note, Landin.Source.No_Source,
               Landin.Source.Empty_Span, "a note"));
      List.Append
        (Make ("L0141", Warning, Landin.Source.No_Source,
               Landin.Source.Empty_Span, "a warning"));
      List.Append
        (Make ("L0140", Error, Landin.Source.No_Source,
               Landin.Source.Empty_Span, "an error"));

      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Render (List, Sources), Expected,
         "every severity has its own word, and errors sort first");
      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Image (Warning), "warning",
         "warning is spelled out");
      Landin.Testing.Check_Equal
        (Item, Landin.Diagnostics.Text.Image (Note), "note",
         "note is spelled out");
      Landin.Testing.Check
        (Item, Role (Primary (Get (List, 1))) = Primary,
         "the primary label knows it is primary");
   end Every_Severity_Is_Spelled;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "diagnostics", "codes are validated",
         Codes_Are_Validated'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "labels and notes are kept",
         Labels_And_Notes_Are_Kept'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "order is independent of arrival",
         Order_Is_Independent_Of_Arrival'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "rendering is stable",
         Rendering_Is_Stable'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "multiple labels render in order",
         Multiple_Labels_Render_In_Order'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "ties are broken deterministically",
         Ties_Are_Broken_Deterministically'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "a sourceless diagnostic says so",
         A_Sourceless_Diagnostic_Says_So'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "an impossible span is reported",
         An_Impossible_Span_Is_Reported'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "rendering sorts its input",
         Rendering_Sorts_Its_Input'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "span ends and arrival order",
         Span_Ends_And_Arrival_Order'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "carets stay on their line",
         Carets_Stay_On_Their_Line'Access);
      Landin.Testing.Register
        (Into, "diagnostics", "every severity is spelled",
         Every_Severity_Is_Spelled'Access);
   end Register;

end Landin.Tests.Diagnostics_Suite;
