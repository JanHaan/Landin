with Ada.Strings.Unbounded;
with Interfaces.C;
with Interfaces.C.Strings;

private package Landin.Platform.Native.Byte_Strings is
   --  Exact foreign bytes. Interfaces.C.Strings.Value stops at NUL even
   --  with a length, so it is unsuitable for source snapshots and captures.
   function Copy
     (Bytes : Interfaces.C.Strings.chars_ptr; Size : Interfaces.C.size_t)
      return Ada.Strings.Unbounded.Unbounded_String;
end Landin.Platform.Native.Byte_Strings;
