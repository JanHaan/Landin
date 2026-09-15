--  Logical compiler-owned hosted identities, shared by checking and emission.
--  No target prefix, libc dependency or machine signature belongs here.
package Landin.Hosted is

   type Host_Helper is
     (No_Host_Helper, Initialize_Arguments, Argument_Count, Argument_Table,
      Argument_At, Argument_At_From, Text_Length, Open_Read, Open_Write,
      Read_Bytes, Write_Bytes, Close_File, Errno_Value, Heap_Allocate,
      Heap_Release);

   function Helper_Name (Helper : Host_Helper) return String
     is (case Helper is
           when No_Host_Helper => "",
           when Initialize_Arguments => "_landin_host_initialize_arguments",
           when Argument_Count => "_landin_host_argument_count",
           when Argument_Table => "_landin_host_argument_table",
           when Argument_At => "_landin_host_argument_at",
           when Argument_At_From => "_landin_host_argument_at_from",
           when Text_Length => "_landin_host_text_length",
           when Open_Read => "_landin_host_open_read",
           when Open_Write => "_landin_host_open_write",
           when Read_Bytes => "_landin_host_read",
           when Write_Bytes => "_landin_host_write",
           when Close_File => "_landin_host_close",
           when Errno_Value => "_landin_host_errno",
           when Heap_Allocate => "_landin_host_heap_allocate",
           when Heap_Release => "_landin_host_heap_release");

   function Helper_Of (Symbol : String) return Host_Helper;

end Landin.Hosted;
