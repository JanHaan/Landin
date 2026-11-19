--  `refine-svd`, the split command `refine svd` runs (D1383, D1384): its
--  whole run is Landin.Splits.Svd's.

with Landin.Splits.Native;
with Landin.Splits.Svd;

procedure Refine_Svd is
begin
   Landin.Splits.Native.Main ("svd", Landin.Splits.Svd.Execute'Access);
end Refine_Svd;
