package body Landin.Diagnostics.Modules is

   package Rows renames Landin.Diagnostics.Catalogue;

   use type Landin.Source.Byte_Offset;

   procedure Report
     (Item    : Failure;
      Source  : Landin.Source.Source_Id;
      Where   : Landin.Source.Span;
      Message : String;
      Note    : String := "";
      Into    : in out Diagnostic_List)
   is
      Row : constant Rows.Code_Name :=
        Code_For (Item);
      Made : Diagnostic :=
        Make
          (Code    => Rows.Code (Row),
           Level   => Rows.Level (Row),
           Source  => Source,
           Where   => Where,
           Message => Message);
   begin
      if Note /= "" then
         Add_Note (Made, Note);
      end if;
      if Rows.Required_Notes (Row) /= Note_Count (Made)
        or else Label_Count (Made) < Rows.Minimum_Secondaries (Row)
        or else Label_Count (Made) > Rows.Maximum_Secondaries (Row)
      then
         raise Compiler_Defect
           with "the catalogue row for " & Rows.Code (Row)
                & " and the diagnostic built for it disagree";
      end if;

      if Rows.Needs_Non_Empty_Span (Row)
        and then Landin.Source.Length (Where) = 0
      then
         raise Compiler_Defect
           with Rows.Code (Row) & " requires a span with bytes in it";
      end if;
      Append (Into, Made);
   end Report;

end Landin.Diagnostics.Modules;
