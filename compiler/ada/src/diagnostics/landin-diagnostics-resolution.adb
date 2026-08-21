package body Landin.Diagnostics.Resolution is

   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.Source.Byte_Offset;

   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String;
      Related : Landin.Provenance.Origin := Landin.Provenance.No_Origin;
      Because : String := "";
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
      if Note /= "" then
         Add_Note (Built, Note);
      end if;

      --  The second label carries its own source, because the earlier
      --  declaration may be in another file.  A sentence with no place to
      --  attach it to is worse than no second label, so it is a defect.
      if Because /= "" then
         if not Landin.Provenance.Is_Known (Related) then
            raise Compiler_Defect
              with Text & " was given a second sentence and no origin";
         end if;

         Add_Label
           (Built,
            Make_Label (Related.Source, Related.Where, Because));
      end if;

      --  The row this code carries is checked against the diagnostic just
      --  built, exactly as Landin.Diagnostics.Syntactic does.
      if Rows.Required_Notes (Named) /= Note_Count (Built)
        or else Rows.Required_Secondaries (Named) /= Label_Count (Built)
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

end Landin.Diagnostics.Resolution;
