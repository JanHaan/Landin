--  What a server analyses when a routine's body does not parse.
--
--  `refine` stops after syntax when a source does not parse, and a server
--  that did the same would answer nothing while a person types: every
--  edit leaves some body half written.  D253 is how it answers anyway
--  without any stage learning to read a hole.  A routine body is the one
--  place a hole cannot take a name away from anything else -- nothing a
--  body declares is visible outside it -- so a body holding every error
--  can be stood in for: its bytes are blanked, line ends kept, and
--  `loop do end loop` written at its start, which every signature accepts
--  because it never finishes.  The stand-in has every offset, line and
--  column of the source, and the unchanged stages check it.
--
--  A body is stood in for only when the parser found its whole shape and
--  every error lies inside it:
--
--  * a module function whose name, parameters, results and declared error
--    set are sound, with an ordinary convention, a Landin body and `=`
--    before it;
--  * not generic, and no `! ...`, whose set the body is what infers;
--  * closed by the `end` the parser matched with it, so the body did not
--    swallow the declarations after it, and with no line inside it that
--    begins in column one, where recovery may have read a declaration as
--    a statement.
--
--  Anything else -- a lost declaration, a hole in a signature, a type or a
--  binding, an unclosed comment -- leaves no stand-in, and the source is
--  reported as `refine` reports it.

with Ada.Containers.Vectors;

with Landin.Source;

package Landin.Server.Holes is

   package Span_Vectors is new Ada.Containers.Vectors
     (Index_Type => Positive, Element_Type => Landin.Source.Span,
      "=" => Landin.Source."=");

   subtype Span_List is Span_Vectors.Vector;

   type Verdict is
     (Sound,     --  it scans and parses; analyse it as it is
      Stood_In,  --  every error lies in a body stood in for
      Refused);  --  some error lies where nothing can stand in

   type Plan (Length : Natural) is record
      Outcome  : Verdict := Refused;
      --  The bytes to analyse: the source itself unless Stood_In.
      Text     : String (1 .. Length);
      --  Each body stood in for, from just after its `=` to the end of
      --  its `end`, in byte order: what the stand-in says about any of
      --  these bytes is not what the source says.
      Held     : Span_List;
   end record;

   --  How Text is to be analysed.  Text is lexed and parsed on its own,
   --  and nothing about it is kept.
   function Plan_For (Text : String) return Plan;

   --  Whether Where touches a held region.
   function Within (Held : Span_List; Where : Landin.Source.Span)
     return Boolean;

end Landin.Server.Holes;
