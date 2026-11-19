--  `refine-site`, the split command `refine site` runs (D1383, D1384): its
--  whole run is Landin.Splits.Site's.

with Landin.Splits.Native;
with Landin.Splits.Site;

procedure Refine_Site is
begin
   Landin.Splits.Native.Main ("site", Landin.Splits.Site.Execute'Access);
end Refine_Site;
