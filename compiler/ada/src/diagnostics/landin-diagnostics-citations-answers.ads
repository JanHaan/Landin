--  Reading a citation as `refine explain` is asked for one (D530).
--
--  A construct is asked for as a note cites it, `[1590]`, or as its bare
--  four digits, `1590`; a decision as `D275` or `d275`.  Anything else is
--  not a citation, and the driver reads it as a diagnostic code.

package Landin.Diagnostics.Citations.Answers is

   --  Whether Asked is written as a construct or a decision is, whether or
   --  not a document defines it.
   function Is_Citation (Asked : String) return Boolean;

   --  Whether a document defines the construct or decision Asked names.
   function Is_Known (Asked : String) return Boolean
     with Pre => Is_Citation (Asked);

   --  What `refine explain` prints: the citation and its title, the
   --  document and, for a decision, its register section, and its page;
   --  with Full, a blank line and the entry's text.  Every line ends LF.
   function Answer (Asked : String; Full : Boolean) return String
     with Pre => Is_Citation (Asked) and then Is_Known (Asked);

   --  The refusal for a citation no document defines.
   function Unknown (Asked : String) return String
     with Pre => Is_Citation (Asked);

end Landin.Diagnostics.Citations.Answers;
