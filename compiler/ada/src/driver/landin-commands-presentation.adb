with Ada.Strings.Fixed;
with Ada.Strings.Unbounded;
with Landin.Byte_Encoding;
with Landin.Diagnostics;
with Landin.Diagnostics.Text;
with Landin.Json;
with Landin.Source;

package body Landin.Commands.Presentation is
   package US renames Ada.Strings.Unbounded;
   package D renames Landin.Diagnostics;
   package J renames Landin.Json;
   use type Landin.Source.Source_Id;
   use type D.Label_Role;
   use type D.Applicability;

   procedure Render
     (Result : in out Landin.Driver.Outcome;
      Format : Style;
      Color : Boolean)
   is
      Text : US.Unbounded_String;
      Original : constant String := US.To_String (Result.Report);
      function Image (Value : Long_Long_Integer) return String is
        (Ada.Strings.Fixed.Trim (Value'Image, Ada.Strings.Both));
      function Path (Source : Landin.Source.Source_Id) return String is
        (if Source /= Landin.Source.No_Source
          and then Natural (Source) <= Natural (Result.Named.Length)
         then Result.Named.Element (Positive (Source)) else "");

      procedure Write_Label (Into : in out J.Builder; Label : D.Label);
      procedure Write_Label (Into : in out J.Builder; Label : D.Label) is
         Name : constant String := Path (D.Source_Of (Label));
      begin
         J.Begin_Object (Into);
         J.Name (Into, "path");
         if Name = "" then
            J.Write_Null (Into);
         else
            J.Write_String (Into, Name);
         end if;
         J.Name (Into, "path_hex");
         J.Write_String (Into, Landin.Byte_Encoding.Hex (Name));
         J.Name (Into, "first_byte");
         J.Write_Integer (Into, Long_Long_Integer (D.Span_Of (Label).First));
         J.Name (Into, "last_byte");
         J.Write_Integer (Into, Long_Long_Integer (D.Span_Of (Label).Last));
         J.Name (Into, "message");
         J.Write_String (Into, D.Message (Label));
         J.Name (Into, "primary");
         J.Write_Boolean (Into, D.Role (Label) = D.Primary);
         J.End_Object (Into);
      end Write_Label;

      procedure JSON_Line (Kind, Message : String);
      procedure JSON_Line (Kind, Message : String) is
      begin
         US.Append (Text, "{""schema"":1,""kind"":" & J.Quoted (Kind)
           & ",""message"":" & J.Quoted (Message) & "}" & ASCII.LF);
      end JSON_Line;
   begin
      if Format = Human then
         if Color then
            declare
               Colored : US.Unbounded_String;
               Cursor : Positive := Original'First;
               Esc : constant String := "" & ASCII.ESC & "[";
            begin
               while Cursor <= Original'Last loop
                  if (Cursor = Original'First
                      or else Original (Cursor - 1) = ASCII.LF)
                    and then Cursor + 5 <= Original'Last
                    and then Original (Cursor .. Cursor + 5) = "error["
                  then
                     US.Append (Colored, Esc & "31merror" & Esc & "0m[");
                     Cursor := Cursor + 6;
                  elsif (Cursor = Original'First
                         or else Original (Cursor - 1) = ASCII.LF)
                    and then Cursor + 7 <= Original'Last
                    and then Original (Cursor .. Cursor + 7) = "warning["
                  then
                     US.Append (Colored, Esc & "33mwarning" & Esc & "0m[");
                     Cursor := Cursor + 8;
                  else
                     US.Append (Colored, Original (Cursor));
                     Cursor := Cursor + 1;
                  end if;
               end loop;
               Result.Report := Colored;
            end;
         end if;
         return;
      end if;
      for Index in 1 .. D.Count (Result.Found) loop
         declare
            Item : constant D.Diagnostic := D.Get (Result.Found, Index);
            Where : Landin.Source.Position;
            Source_Path : constant String := Path
              (D.Source_Of (D.Primary (Item)));
         begin
            if Index <= Natural (Result.Positions.Length) then
               Where := Result.Positions.Element (Index);
            end if;
            if Format = Short then
               if Source_Path /= "" then
                  US.Append (Text, Source_Path & ":"
                    & Image (Long_Long_Integer (Where.Line)) & ":"
                    & Image (Long_Long_Integer (Where.Column)) & ": ");
               end if;
               US.Append (Text, D.Text.Image (D.Level (Item)) & "["
                 & D.Code (Item) & "]: " & D.Message (D.Primary (Item))
                 & ASCII.LF);
            else
               declare
                  Into : J.Builder;
               begin
                  J.Begin_Object (Into);
                  J.Name (Into, "schema");
                  J.Write_Integer (Into, 1);
                  J.Name (Into, "kind");
                  J.Write_String (Into, "diagnostic");
                  J.Name (Into, "code");
                  J.Write_String (Into, D.Code (Item));
                  J.Name (Into, "severity");
                  J.Write_String (Into, D.Text.Image (D.Level (Item)));
                  J.Name (Into, "message");
                  J.Write_String (Into, D.Message (D.Primary (Item)));
                  J.Name (Into, "line");
                  J.Write_Integer (Into, Long_Long_Integer (Where.Line));
                  J.Name (Into, "byte_column");
                  J.Write_Integer (Into, Long_Long_Integer (Where.Column));
                  J.Name (Into, "labels");
                  J.Begin_Array (Into);
                  Write_Label (Into, D.Primary (Item));
                  for Position in 1 .. D.Label_Count (Item) loop
                     Write_Label (Into, D.Nth_Label (Item, Position));
                  end loop;
                  J.End_Array (Into);
                  J.Name (Into, "notes");
                  J.Begin_Array (Into);
                  for Position in 1 .. D.Note_Count (Item) loop
                     J.Write_String (Into, D.Nth_Note (Item, Position));
                  end loop;
                  J.End_Array (Into);
                  J.Name (Into, "fixes");
                  J.Begin_Array (Into);
                  for Position in 1 .. D.Fix_Count (Item) loop
                     declare
                        Fix : constant D.Fix := D.Nth_Fix (Item, Position);
                     begin
                        J.Begin_Object (Into);
                        J.Name (Into, "message");
                        J.Write_String (Into, D.Message (Fix));
                        J.Name (Into, "applicability");
                        J.Write_String (Into,
                          (if D.Level (Fix) = D.Exact then "exact"
                           else "likely"));
                        J.Name (Into, "edits");
                        J.Begin_Array (Into);
                        for Edit_Index in 1 .. D.Edit_Count (Fix) loop
                           declare
                              Edit : constant D.Edit :=
                                D.Nth_Edit (Fix, Edit_Index);
                           begin
                              J.Begin_Object (Into);
                              J.Name (Into, "path");
                              J.Write_String (Into, Path (D.Source_Of (Edit)));
                              J.Name (Into, "path_hex");
                              J.Write_String (Into, Landin.Byte_Encoding.Hex
                                (Path (D.Source_Of (Edit))));
                              J.Name (Into, "first_byte");
                              J.Write_Integer (Into, Long_Long_Integer
                                (D.Span_Of (Edit).First));
                              J.Name (Into, "last_byte");
                              J.Write_Integer (Into, Long_Long_Integer
                                (D.Span_Of (Edit).Last));
                              J.Name (Into, "replacement");
                              J.Write_String (Into, D.Replacement (Edit));
                              J.End_Object (Into);
                           end;
                        end loop;
                        J.End_Array (Into);
                        J.End_Array (Into);
                     end;
                  end loop;
                  J.End_Array (Into);
                  J.End_Object (Into);
                  US.Append (Text, J.Result (Into) & ASCII.LF);
               end;
            end if;
         end;
      end loop;
      if Result.Status >= Landin.Driver.Status_Defect
        or else (D.Count (Result.Found) = 0 and then Original /= "")
      then
         if Format = JSON then
            JSON_Line ("failure", Original);
         else
            US.Append (Text, Original);
         end if;
      end if;
      Result.Report := Text;
      if Format = JSON and then US.Length (Result.Trace) > 0 then
         Text := US.Null_Unbounded_String;
         JSON_Line ("trace", US.To_String (Result.Trace));
         Result.Trace := Text;
      end if;
   end Render;
end Landin.Commands.Presentation;
