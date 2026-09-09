--  Byte-preserving ASCII representation, independent of text encodings,
--  filesystem rules and the lower bound of the input string.
package Landin.Byte_Encoding is
   pragma Pure;

   function Hex (Value : String) return String;
end Landin.Byte_Encoding;
