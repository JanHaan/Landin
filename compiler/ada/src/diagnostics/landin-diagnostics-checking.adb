package body Landin.Diagnostics.Checking is

   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.Source.Byte_Offset;

   Strict_Places : Boolean := False with Atomic;

   procedure Refuse_Repeated_Places (Strict : Boolean) is
   begin
      Strict_Places := Strict;
   end Refuse_Repeated_Places;

   function Refuses_Repeated_Places return Boolean is (Strict_Places);

   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String := "";
      Related : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Because : String := "";
      Refused : Refused_Use := Struct_Value;
      Route   : String := "";
      Fixes   : Fix_List := No_Fixes;
      Into    : in out Diagnostic_List)
   is
      Named : constant Rows.Code_Name := Code_For (Item);
      Text  : constant Code_String := Rows.Code (Named);
      Built : Diagnostic :=
        Make (Code    => Text,
              Level   => Rows.Level (Named),
              Source  => Source,
              Where   => Where,
              Message => Message);
   begin
      --  [1830] promises two facts and the checker writes neither: the
      --  construct's paragraph and what it is both come out of the tables
      --  above.  Conformance failures use the ordinary note argument; their
      --  exact note and related-source shape is catalogued.  A note given
      --  beside the two facts would be dropped without a word, so it is a
      --  defect where it was written: what to write instead is the Route.
      if Item = Unsupported_Use and then Note /= "" then
         raise Compiler_Defect
           with Text & " takes its notes from its row and was given one: "
                & Note;
      end if;
      if Item = Unsupported_Use then
         Add_Note
           (Built, "the tour describes it at " & Construct (Refused));
         Add_Note
           (Built,
            (case Standing (Refused) is
                when Recorded_Boundary =>
                   "this is a recorded source-form boundary",
                when Withdrawn =>
                   "this form is withdrawn; pass an ordinary allocator",
                when Transferred =>
                   "this is transferred to Language evolution"));
      elsif Note /= "" then
         Add_Note (Built, Note);
      end if;

      --  The route follows the facts, and the row says whether the code
      --  admits one.
      if Route /= "" then
         Add_Note (Built, Route);
      end if;

      if Because /= "" then
         if not Landin.Provenance.Is_Known (Related) then
            raise Compiler_Defect
              with Text & " was given a related label and no origin";
         end if;
         --  A second place is a second place: a check that knows nothing of
         --  its context names the construct it was written in, never the
         --  refused span again.  That is a defect of the check, and the
         --  test program is held to it; a compiler someone runs still has
         --  a true diagnostic to give, so it gives it without the label
         --  that says nothing (D1251).  A row that promises a label keeps
         --  it even so: the row is what `refine explain` and the catalogue
         --  say of every occurrence.
         if Landin.Source."=" (Related.Source, Source)
           and then Landin.Source."=" (Related.Where, Where)
         then
            if Strict_Places then
               raise Compiler_Defect
                 with Text & " was given a secondary on its own span: "
                      & Because;
            end if;
            if Rows.Minimum_Secondaries (Named) > 0 then
               Add_Label
                 (Built,
                  Make_Label (Related.Source, Related.Where, Because));
            end if;
         else
            Add_Label
              (Built,
               Make_Label (Related.Source, Related.Where, Because));
         end if;
      end if;

      for One of Fixes loop
         Add_Fix (Built, One);
      end loop;

      --  The row this code carries is checked against the diagnostic just
      --  built, for Landin.Diagnostics.Lexical's reason: a code whose
      --  occurrences do not carry what it promises is worse than none.
      if not Rows.Admits_Notes (Named, Note_Count (Built))
        or else Label_Count (Built) < Rows.Minimum_Secondaries (Named)
        or else Label_Count (Built) > Rows.Maximum_Secondaries (Named)
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

      Append (Into, Built);
   end Report;

end Landin.Diagnostics.Checking;
