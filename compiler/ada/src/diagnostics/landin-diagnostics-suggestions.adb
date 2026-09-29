package body Landin.Diagnostics.Suggestions is

   --  Three rows of the table suffice, because a swap looks back two.  The
   --  names are short, and this runs only on a path that already refused
   --  the program, so the quadratic table is never on an accepted build.
   function Distance (Left, Right : String) return Natural is
      type Row is array (0 .. Right'Length) of Natural;
      Two_Back, Previous, Current : Row;
   begin
      for Column in Row'Range loop
         Previous (Column) := Column;
      end loop;
      Two_Back := Previous;

      for Line in 1 .. Left'Length loop
         Current (0) := Line;
         for Column in 1 .. Right'Length loop
            declare
               Here  : constant Character := Left (Left'First + Line - 1);
               There : constant Character := Right (Right'First + Column - 1);
               Cost  : constant Natural := (if Here = There then 0 else 1);
               Best  : Natural := Natural'Min
                 (Natural'Min
                    (Previous (Column) + 1, Current (Column - 1) + 1),
                  Previous (Column - 1) + Cost);
            begin
               if Line > 1 and then Column > 1
                 and then Here = Right (Right'First + Column - 2)
                 and then Left (Left'First + Line - 2) = There
               then
                  Best := Natural'Min (Best, Two_Back (Column - 2) + 1);
               end if;
               Current (Column) := Best;
            end;
         end loop;
         Two_Back := Previous;
         Previous := Current;
      end loop;

      return Previous (Right'Length);
   end Distance;

   function Near (Written, Candidate : String) return Boolean is
      Limit : constant Natural := Bound (Written);
      Apart : constant Natural :=
        abs (Written'Length - Candidate'Length);
   begin
      --  The length difference is a lower bound on the distance, so most
      --  candidates are refused without building a table.
      if Written = Candidate or else Apart > Limit then
         return False;
      end if;

      declare
         Found : constant Natural := Distance (Written, Candidate);
      begin
         return Found <= Limit
           and then Found < Written'Length
           and then Found < Candidate'Length;
      end;
   end Near;

   function Before (Left, Right : Entry_Kind) return Boolean
     is (Left.Distance < Right.Distance
         or else (Left.Distance = Right.Distance
                  and then (Left.Depth < Right.Depth
                            or else (Left.Depth = Right.Depth
                                     and then Left.Spelling
                                                < Right.Spelling))));

   procedure Consider
     (Into      : in out Ranking;
      Written   : String;
      Candidate : String;
      Depth     : Natural := 0)
   is
   begin
      if not Near (Written, Candidate) then
         return;
      end if;

      declare
         Offered : constant Entry_Kind :=
           (Length   => Candidate'Length,
            Distance => Distance (Written, Candidate),
            Depth    => Depth,
            Spelling => Candidate);
         Position : Positive := 1;
      begin
         --  One spelling is one suggestion, at its innermost depth.
         for Index in 1 .. Natural (Into.Kept.Length) loop
            if Into.Kept.Element (Index).Spelling = Candidate then
               if Before (Offered, Into.Kept.Element (Index)) then
                  Into.Kept.Delete (Index);
                  exit;
               else
                  return;
               end if;
            end if;
         end loop;

         while Position <= Natural (Into.Kept.Length)
           and then Before (Into.Kept.Element (Position), Offered)
         loop
            Position := Position + 1;
         end loop;
         Into.Kept.Insert (Position, Offered);
      end;
   end Consider;

   function Count (Of_Ranking : Ranking) return Natural is
      Kept : Natural := 0;
   begin
      for Index in 1 .. Natural (Of_Ranking.Kept.Length) loop
         exit when Kept = Most
           or else Of_Ranking.Kept.Element (Index).Distance
                     /= Of_Ranking.Kept.Element (1).Distance;
         Kept := Kept + 1;
      end loop;
      return Kept;
   end Count;

   function Nth (Of_Ranking : Ranking; Index : Positive) return String
     is (Of_Ranking.Kept.Element (Index).Spelling);

end Landin.Diagnostics.Suggestions;
