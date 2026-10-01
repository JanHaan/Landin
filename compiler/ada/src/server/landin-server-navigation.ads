--  What is at a place in a checked module, for an editor.
--
--  Three questions, each answered from the tables the stages filled and
--  nothing else: which name a byte is in, where what it names is declared,
--  and what that is -- its type as the checker spells one, the declaration
--  as the source writes it, and its doc comment [2000].  An answer exists
--  only where the stages decided one: a name resolution left unbound, a
--  node the checker did not type and a byte inside a held body each answer
--  nothing, never a guess.

with Landin.Server.Analysis;
with Landin.Source;
with Landin.Stages;

package Landin.Server.Navigation is

   type Place is record
      Source : Landin.Source.Source_Id := Landin.Source.No_Source;
      Where  : Landin.Source.Span := Landin.Source.Empty_Span;
   end record;

   No_Place : constant Place;

   --  Where the name at Offset in Source is declared: the declared name's
   --  own span.  No_Place for anything but a bound name, a declaring name
   --  included, which is its own declaration.
   function Definition
     (Context : in out Landin.Stages.Compilation;
      Answer  : Landin.Server.Analysis.Result;
      Source  : Landin.Source.Source_Id;
      Offset  : Landin.Source.Byte_Offset) return Place;

   type Description (Length : Natural) is record
      --  The name or expression described, in Source; empty for none.
      Range_Of : Place;
      --  Markdown, empty when there is nothing to say.
      Text     : String (1 .. Length);
   end record;

   --  What is at Offset: a name's declaration and type and doc comment, or
   --  an expression's type.
   function Hover
     (Context : in out Landin.Stages.Compilation;
      Answer  : Landin.Server.Analysis.Result;
      Source  : Landin.Source.Source_Id;
      Offset  : Landin.Source.Byte_Offset) return Description;

   --  The doc comment [2000] above the line Offset is on in Text, its
   --  `---` and one blank after it gone, lines joined with LF.
   function Doc_Comment
     (Text : String; Offset : Landin.Source.Byte_Offset) return String;

private

   No_Place : constant Place :=
     (Landin.Source.No_Source, Landin.Source.Empty_Span);

end Landin.Server.Navigation;
