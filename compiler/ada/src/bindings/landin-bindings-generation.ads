--  The generator: from a policy's selections and Clang's AST, the four
--  outputs.  Selection resolves each policy entry against the AST;
--  collection walks what the selections depend on, classifying every
--  record reached by value as a native `layout(c)` record or C-owned
--  storage; rendering writes each declaration's Landin, C and metadata in
--  an order that depends on nothing but names.

private package Landin.Bindings.Generation is

   --  Resolve every policy entry against the AST already read.
   procedure Select_Declarations (S : Handle);

   --  Everything the selections depend on, classified.
   procedure Collect_Dependencies (S : Handle);

   --  The identities of the enums whose compatible type the probe asks,
   --  in the order of their Landin names.
   function Probe_Order (S : Handle) return String_Vectors.Vector;

   --  Render the four outputs into S.Outputs.
   procedure Generate (S : Handle; Defines : Landin.Platform.Path_List);

end Landin.Bindings.Generation;
