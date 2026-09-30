with Ada.Containers.Indefinite_Vectors;
with Ada.Strings.Unbounded;

package body Landin.Testing.Fixes is

   package Diag renames Landin.Diagnostics;
   package Unbounded renames Ada.Strings.Unbounded;

   use type Landin.Source.Byte_Offset;
   use type Landin.Source.Source_Id;

   package Edit_Vectors is new Ada.Containers.Indefinite_Vectors
     (Index_Type => Positive, Element_Type => Diag.Edit,
      "=" => Diag."=");

   --  The edits of Source, in byte order, from the first fix of every
   --  diagnostic.
   function Collected
     (Found  : Diag.Diagnostic_List;
      Source : Landin.Source.Source_Id) return Edit_Vectors.Vector;

   function Collected
     (Found  : Diag.Diagnostic_List;
      Source : Landin.Source.Source_Id) return Edit_Vectors.Vector
   is
      Result : Edit_Vectors.Vector;
   begin
      for Index in 1 .. Diag.Count (Found) loop
         declare
            Item : constant Diag.Diagnostic := Diag.Get (Found, Index);
         begin
            if Diag.Fix_Count (Item) > 0 then
               declare
                  First : constant Diag.Fix := Diag.Nth_Fix (Item, 1);
               begin
                  for Position in 1 .. Diag.Edit_Count (First) loop
                     declare
                        One : constant Diag.Edit :=
                          Diag.Nth_Edit (First, Position);
                        At_Index : Positive := 1;
                     begin
                        if Diag.Source_Of (One) = Source then
                           while At_Index <= Natural (Result.Length)
                             and then Diag.Span_Of
                               (Result.Element (At_Index)).First
                                 <= Diag.Span_Of (One).First
                           loop
                              At_Index := At_Index + 1;
                           end loop;
                           Result.Insert (At_Index, One);
                        end if;
                     end;
                  end loop;
               end;
            end if;
         end;
      end loop;
      return Result;
   end Collected;

   function Edits
     (Found  : Diag.Diagnostic_List;
      Source : Landin.Source.Source_Id) return Boolean
     is (not Collected (Found, Source).Is_Empty);

   function Applied
     (Found   : Diag.Diagnostic_List;
      Source  : Landin.Source.Source_Id;
      Text    : String;
      Clashed : out Boolean) return String
   is
      Ordered : constant Edit_Vectors.Vector := Collected (Found, Source);
      Result  : Unbounded.Unbounded_String :=
        Unbounded.To_Unbounded_String (Text);
   begin
      Clashed := False;

      --  Adjacent edits in byte order may touch and may not overlap; two
      --  insertions at one offset have no order and clash as well.
      for Index in 2 .. Natural (Ordered.Length) loop
         declare
            Before : constant Landin.Source.Span :=
              Diag.Span_Of (Ordered.Element (Index - 1));
            After  : constant Landin.Source.Span :=
              Diag.Span_Of (Ordered.Element (Index));
         begin
            if After.First < Before.Last
              or else (After.First = Before.First
                       and then Landin.Source.Length (Before) = 0
                       and then Landin.Source.Length (After) = 0)
            then
               Clashed := True;
               return Text;
            end if;
         end;
      end loop;

      for Index in reverse 1 .. Natural (Ordered.Length) loop
         declare
            One   : constant Diag.Edit := Ordered.Element (Index);
            Where : constant Landin.Source.Span := Diag.Span_Of (One);
         begin
            Unbounded.Replace_Slice
              (Result,
               Low  => Natural (Where.First) + 1,
               High => Natural (Where.Last),
               By   => Diag.Replacement (One));
         end;
      end loop;

      return Unbounded.To_String (Result);
   end Applied;

end Landin.Testing.Fixes;
