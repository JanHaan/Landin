package body Landin.Debugging is

   use type Landin.Source.Source_Id;
   use type Landin.Provenance.Declaration_Id;

   procedure Append
     (Into : in out Information; Snapshot : Landin.Source.Snapshot)
   is
   begin
      if Landin.Source.Id (Snapshot)
        /= Landin.Source.Source_Id (Count (Into) + 1)
      then
         raise Compiler_Defect with "debug source identities are not dense";
      end if;
      Into.Snapshots.Append (Snapshot);
   end Append;

   function Count (Info : Information) return Natural is
     (Natural (Info.Snapshots.Length));

   function Source
     (Info : Information; Id : Landin.Source.Source_Id)
      return Landin.Source.Snapshot
   is
   begin
      if Id = Landin.Source.No_Source or else Natural (Id) > Count (Info) then
         raise Compiler_Defect with "unknown debug source identity";
      end if;
      return Info.Snapshots (Positive (Id));
   end Source;

   procedure Set_Directory (Into : in out Information; Path : String) is
   begin
      Into.Compile_Directory := Ada.Strings.Unbounded.To_Unbounded_String
        (Path);
   end Set_Directory;

   function Directory (Info : Information) return String is
     (Ada.Strings.Unbounded.To_String (Info.Compile_Directory));

   procedure Append_Result_Name
     (Into : in out Information;
      Binding : Landin.Provenance.Declaration_Id;
      Name : Landin.Source.Names.Name_Id)
   is
   begin
      if Binding = Landin.Provenance.No_Declaration then
         raise Compiler_Defect with "debug result has no declaration";
      end if;
      while Natural (Into.Result_Names.Length) < Natural (Binding) loop
         Into.Result_Names.Append (Name_Vectors.Empty_Vector);
      end loop;
      Into.Result_Names (Positive (Binding)).Append (Name);
   end Append_Result_Name;

   function Result_Name
     (Info : Information;
      Binding : Landin.Provenance.Declaration_Id;
      Index : Positive) return Landin.Source.Names.Name_Id
   is
   begin
      if Binding = Landin.Provenance.No_Declaration
        or else Natural (Binding) > Natural (Info.Result_Names.Length)
        or else Index > Natural
          (Info.Result_Names (Positive (Binding)).Length)
      then
         return Landin.Source.Names.No_Name;
      end if;
      return Info.Result_Names (Positive (Binding)) (Index);
   end Result_Name;

end Landin.Debugging;
