--  What `refine explain --full` adds for a construct or a decision (D530):
--  a construct's own text up to its next heading, and a decision's
--  `Chosen` paragraphs.  Apart from Landin.Diagnostics.Citations because it
--  is most of the generated text, and a paragraph's edit then recompiles
--  only this.
--
--  Markdown's inline marks are rendered for a terminal: a code span keeps
--  its backticks, as an explanation's does, a link is its text and bold is
--  its words.  A paragraph is one line, a list item or a table row keeps
--  its own, and a fenced block is indented four spaces.

package Landin.Diagnostics.Citations.Texts is

   function Construct_Text (Number : Natural) return String;
   function Decision_Text (Number : Natural) return String;

end Landin.Diagnostics.Citations.Texts;
