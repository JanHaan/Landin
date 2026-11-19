--  `refine-bindings`, the split command `refine bindings` runs (D1383,
--  D1384): its whole run is Landin.Splits.Bindings's.

with Landin.Splits.Native;
with Landin.Splits.Bindings;

procedure Refine_Bindings is
begin
   Landin.Splits.Native.Main
     ("bindings", Landin.Splits.Bindings.Execute'Access);
end Refine_Bindings;
