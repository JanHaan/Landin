with Ada.Unchecked_Conversion;
with System;
with System.Storage_Elements;

package body Landin.Platform.Native.Byte_Strings is
   function Copy
     (Bytes : Interfaces.C.Strings.chars_ptr; Size : Interfaces.C.size_t)
      return Ada.Strings.Unbounded.Unbounded_String
   is
      use type Interfaces.C.size_t;
      use System.Storage_Elements;
      function Address is new Ada.Unchecked_Conversion
        (Interfaces.C.Strings.chars_ptr, System.Address);
      function Memory_Copy
        (Target, Source : System.Address; Count : Interfaces.C.size_t)
         return System.Address
        with Import, Convention => C, External_Name => "memcpy";
      Result : Ada.Strings.Unbounded.Unbounded_String;
      Buffer : String (1 .. 64 * 1024);
      Offset : Interfaces.C.size_t := 0;
   begin
      while Offset < Size loop
         declare
            Count : constant Positive := Positive
              (Interfaces.C.size_t'Min (Buffer'Length, Size - Offset));
            Ignored : constant System.Address := Memory_Copy
              (Buffer'Address, Address (Bytes) + Storage_Offset (Offset),
               Interfaces.C.size_t (Count));
            pragma Unreferenced (Ignored);
         begin
            Ada.Strings.Unbounded.Append (Result, Buffer (1 .. Count));
            Offset := Offset + Interfaces.C.size_t (Count);
         end;
      end loop;
      return Result;
   end Copy;
end Landin.Platform.Native.Byte_Strings;
