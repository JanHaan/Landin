with Ada.Containers.Indefinite_Vectors;

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

   procedure Replace
     (Host : in out Overlay_Filesystem; Path : String; Content : String) is
   begin
      Host.Replaced.Include (Path, Content);
   end Replace;

   overriding function Exists
     (Host : Overlay_Filesystem; Path : String) return Boolean
     is (Host.Replaced.Contains (Path) or else Host.Real.Exists (Path));

   overriding function Working_Directory
     (Host : Overlay_Filesystem) return String
     is (Host.Real.Working_Directory);

   overriding function Paths_Overlap
     (Host : Overlay_Filesystem; Left, Right : String) return Boolean
     is (Host.Real.Paths_Overlap (Left, Right));

   overriding function Same_File
     (Host : Overlay_Filesystem; Left, Right : String) return Boolean
     is (Host.Real.Same_File (Left, Right));

   overriding function Is_Directory
     (Host : Overlay_Filesystem; Path : String) return Boolean
     is (Host.Real.Is_Directory (Path));

   overriding procedure Read_File
     (Host    : Overlay_Filesystem;
      Path    : String;
      Content : out Ada.Strings.Unbounded.Unbounded_String;
      Status  : out Landin.Platform.Read_Status)
   is
      Found : constant Content_Maps.Cursor := Host.Replaced.Find (Path);
   begin
      if Content_Maps.Has_Element (Found) then
         Content := Unbounded.To_Unbounded_String
           (Content_Maps.Element (Found));
         Status := Landin.Platform.Read_Ok;
      else
         Host.Real.Read_File (Path, Content, Status);
      end if;
   end Read_File;

   overriding procedure Write_File
     (Host    : Overlay_Filesystem;
      Path    : String;
      Content : String;
      Status  : out Landin.Platform.Write_Status)
   is
      pragma Unreferenced (Host, Path, Content);
   begin
      Status := Landin.Platform.Not_Writable;
   end Write_File;

   overriding procedure Remove_File
     (Host   : Overlay_Filesystem;
      Path   : String;
      Status : out Landin.Platform.Remove_Status)
   is
      pragma Unreferenced (Host, Path);
   begin
      Status := Landin.Platform.Not_Removable;
   end Remove_File;

   overriding procedure List_Directory
     (Host    : Overlay_Filesystem;
      Path    : String;
      Entries : out Landin.Platform.Path_List;
      Status  : out Landin.Platform.List_Status)
   is
   begin
      Host.Real.List_Directory (Path, Entries, Status);
   end List_Directory;

end Landin.Testing.Fixes;
