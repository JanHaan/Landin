--  Whether a stream gives back the file it was read from.
--
--  The scan keeps every byte that is not a token as a piece of space, and
--  the claim that makes that worth having is that the tokens and the pieces
--  together are the file, byte for byte.  This is the check, written again
--  from [1750] and [1780] rather than borrowed from the scanner: it lays the
--  tokens and the pieces end to end, and requires them to meet without a
--  gap or an overlap, to cover the file, and each piece to be
--  what its kind says it is.  Leading is held to the same walk.
--
--  A stream holds spans and not bytes: the bytes are the snapshot's.  What
--  this proves is that every byte of the file is in exactly one token or
--  piece, and that each piece's bytes are the form its kind names, so the
--  file is the tokens' and the pieces' slices laid end to end.

with Landin.Tokens;

package Landin.Testing.Layout is

   --  Empty when Stream reproduces Text, which must be the text Stream was
   --  read from; otherwise what went wrong first, and where.
   function Problem
     (Text : String; Stream : Landin.Tokens.Token_Stream) return String;

   Not_Reproduced : exception;

   --  Raises Not_Reproduced with the Problem, for a caller that reads many
   --  files and has no context to fail.
   procedure Require
     (Text : String; Stream : Landin.Tokens.Token_Stream);

end Landin.Testing.Layout;
