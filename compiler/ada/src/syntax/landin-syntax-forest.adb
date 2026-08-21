with Landin.Syntax.Parser;

package body Landin.Syntax.Forest is

   function Count (Of_Forest : Table) return Natural
     is (Natural (Of_Forest.Items.Length));

   procedure Add
     (Into   : in out Table;
      From   : Landin.Tokens.Token_Stream;
      Names  : in out Landin.Source.Names.Table;
      Report : in out Landin.Diagnostics.Diagnostic_List)
   is
   begin
      --  The one allocator in the frontend.  The value is a function call
      --  because a limited object can be built nowhere else; see the
      --  header for why it is never freed.
      Into.Items.Append
        (new Tree'(Landin.Syntax.Parser.Parse (From, Names, Report)));
   end Add;

   function Tree_Of (Of_Forest : Table; Id : Landin.Source.Source_Id)
     return not null access constant Tree
     is (Of_Forest.Items.Element (Positive (Id)));

end Landin.Syntax.Forest;
