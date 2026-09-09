with Landin.Stages;

--  Off-target provenance adapter. All input is held in the compilation;
--  rendering performs no host reads and adds no data to the executable.
package Landin.Build_Reports.Sources is
   function JSON
     (Of_Report : Report;
      Context : in out Landin.Stages.Compilation;
      Options : Landin.Optimization.Options) return String;
end Landin.Build_Reports.Sources;
