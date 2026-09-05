package body Landin.Diagnostics.Checking is

   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.Source.Byte_Offset;

   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String := "";
      Related : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Because : String := "";
      Refused : Refused_Use := Struct_Value;
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
      --  construct's paragraph and the work that enables it both come out
      --  of the tables above.  Conformance failures use the ordinary note
      --  argument; their exact note and related-source shape is catalogued.
      if Item = Unsupported_Use then
         Add_Note
           (Built, "the tour describes it at " & Construct (Refused));
         Add_Note
           (Built,
            "ROADMAP.md " & Enabled_By (Refused)
            & " is where it is enabled");
      elsif Note /= "" then
         Add_Note (Built, Note);
      end if;

      if Because /= "" then
         if not Landin.Provenance.Is_Known (Related) then
            raise Compiler_Defect
              with Text & " was given a related label and no origin";
         end if;

         Add_Label
           (Built,
            Make_Label (Related.Source, Related.Where, Because));
      end if;

      --  The row this code carries is checked against the diagnostic just
      --  built, for Landin.Diagnostics.Lexical's reason: a code whose
      --  occurrences do not carry what it promises is worse than none.
      if Rows.Required_Notes (Named) /= Note_Count (Built)
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
