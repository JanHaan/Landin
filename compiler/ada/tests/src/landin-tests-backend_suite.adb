--  The frame a routine gets, and the assembly emitted against it.
--
--  These cases read the text, because the text is what an assembler is
--  handed and R1.80's exit evidence asks for it to be deterministic.  The
--  first case asserts a whole program's assembly rather than a substring
--  of it: what is being pinned is every instruction and its order, and a
--  containment check would pass on a prologue that had lost its frame
--  pointer.  That the assembly is also *correct* is what running it on
--  Linux x86-64 says, and this suite does not claim to say it.
--
--  The frame cases are separate from the emission ones on purpose.  A
--  cell's offset is target arithmetic and `Landin.Backend` computes it
--  without naming a machine, so a 32-bit description must lay out the
--  same item differently on this 64-bit host; that is the rule
--  `compiler/ada/README.md` states, checked here rather than assumed.

with Ada.Strings.Fixed;

with Landin.Backend;
with Landin.Backend.X86_64;
with Landin.IR;
with Landin.Source;
with Landin.Stages.Checking;
with Landin.Stages.Lowering;
with Landin.Stages.Resolution;
with Landin.Stages.Syntax;
with Landin.Targets;
with Landin.Types;

package body Landin.Tests.Backend_Suite is

   package IR renames Landin.IR;

   function Contains (Text : String; Needle : String) return Boolean is
     (Ada.Strings.Fixed.Index (Text, Needle) > 0);

   use type Landin.Source.Source_Id;
   use type Landin.Targets.Byte_Count;
   use type Landin.Targets.Scalar_Size;

   Frontend : aliased Landin.Stages.Syntax.Instance;
   Names    : aliased Landin.Stages.Resolution.Instance;
   Checker  : aliased Landin.Stages.Checking.Instance;
   Lowerer  : aliased Landin.Stages.Lowering.Instance;

   LF : constant Character := Character'Val (10);
   HT : constant Character := Character'Val (9);

   procedure Lower
     (Work : in out Landin.Stages.Compilation;
      Text : String;
      Ran  : out Natural);

   procedure Lower
     (Work : in out Landin.Stages.Compilation;
      Text : String;
      Ran  : out Natural)
   is
      Order   : Landin.Stages.Pipeline;
      Written : constant Landin.Source.Source_Id :=
        Landin.Stages.Add_Source (Work, "back.ldn", Text);
   begin
      pragma Assert (Written /= Landin.Source.No_Source);
      Landin.Stages.Append (Order, Frontend'Access);
      Landin.Stages.Append (Order, Names'Access);
      Landin.Stages.Append (Order, Checker'Access);
      Landin.Stages.Append (Order, Lowerer'Access);
      Ran := Landin.Stages.Run (Order, Work);
   end Lower;

   function Emitted (Work : in out Landin.Stages.Compilation) return String
     is (Landin.Backend.X86_64.Text
           (Landin.Stages.Code (Work).all,
            Landin.Stages.Meanings (Work).all,
            Landin.Stages.Identities (Work).all,
            Landin.Stages.Target (Work)));

   ------------------------------------------------------------------
   --  Emission
   ------------------------------------------------------------------

   --  [1970]'s entry shape, and the whole of what it emits.  Every value
   --  is stored to its own cell and reloaded, which is the baseline
   --  `Landin.Backend`'s header states the cost of rather than hides.
   procedure A_Constant_Return_Emits_Its_Whole_Frame
     (Item : in out Landin.Testing.Context);

   procedure A_Constant_Return_Emits_Its_Whole_Frame
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;

      Expected : constant String :=
        HT & ".text" & LF
        & HT & ".globl main" & LF
        & HT & ".type main, @function" & LF
        & "main:" & LF
        & HT & "pushq %rbp" & LF
        & HT & "movq %rsp, %rbp" & LF
        & HT & "subq $16, %rsp" & LF
        & ".L1_1:" & LF
        & HT & "movabsq $42, %rax" & LF
        & HT & "movl %eax, -8(%rbp)" & LF
        & HT & "movl -8(%rbp), %eax" & LF
        & HT & "movl %eax, -4(%rbp)" & LF
        & HT & "movl -4(%rbp), %eax" & LF
        & HT & "movl %eax, -12(%rbp)" & LF
        & HT & "movl -12(%rbp), %eax" & LF
        & HT & "movq %rbp, %rsp" & LF
        & HT & "popq %rbp" & LF
        & HT & "ret" & LF
        & HT & ".size main, .-main" & LF
        & HT & ".section .note.GNU-stack,"""",@progbits" & LF;
   begin
      Lower
        (Work,
         "public main: () -> (code: i32) =" & LF
         & "    code = 42" & LF
         & "end main" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");
      Landin.Testing.Check
        (Item, not Landin.Stages.Failed (Work), "the program is accepted");
      Landin.Testing.Check_Equal
        (Item, Emitted (Work), Expected,
         "the entry emits its frame, its value cells and its return");
   end A_Constant_Return_Emits_Its_Whole_Frame;

   --  [1740]'s `public` is what puts a symbol in the object's table, and
   --  a function without it is emitted and not exported.
   procedure Only_A_Public_Routine_Is_Made_Global
     (Item : in out Landin.Testing.Context);

   procedure Only_A_Public_Routine_Is_Made_Global
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: () -> (r: u32) =" & LF & "    r = 1" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & ".type f, @function"),
            "the routine is emitted");
         Landin.Testing.Check
           (Item, not Contains (Text, ".globl"),
            "nothing declared it public, so nothing is global");
      end;
   end Only_A_Public_Routine_Is_Made_Global;

   --  [1650]'s C ABI hands the first integer arguments in registers, and
   --  a parameter is a slot the caller filled, so the prologue is where
   --  the register becomes a cell.
   procedure A_Parameter_Is_Stored_From_Its_Register
     (Item : in out Landin.Testing.Context);

   procedure A_Parameter_Is_Stored_From_Its_Register
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u32, b: u64) -> (r: u32) =" & LF
         & "    r = a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "movl %edi, -4(%rbp)"),
            "the first parameter arrives in the first register, u32 wide");
         Landin.Testing.Check
           (Item,
            Contains (Text, HT & "movq %rsi, -16(%rbp)"),
            "the second arrives in the second register, u64 wide");
      end;
   end A_Parameter_Is_Stored_From_Its_Register;

   --  Every block gets a label, and a Branch spells both of its edges:
   --  the taken one as a condition and the other as a jump, so no block
   --  falls through to whichever one the emitter happened to print next.
   procedure A_Branch_Names_Both_Of_Its_Edges
     (Item : in out Landin.Testing.Context);

   procedure A_Branch_Names_Both_Of_Its_Edges
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (c: bool) -> (r: u32) =" & LF
         & "    if c then" & LF
         & "        r = 1" & LF
         & "    else" & LF
         & "        r = 2" & LF
         & "    end if" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "cmpb $0, "),
            "a bool is tested as the one byte it occupies");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jne .L1_3"),
            "the taken edge is the branch's target");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jmp .L1_4"),
            "the other edge is spelt and not fallen through to");
         Landin.Testing.Check
           (Item, Contains (Text, ".L1_5:"),
            "every block carries a label");
      end;
   end A_Branch_Names_Both_Of_Its_Edges;

   --  [0300] makes ordinary unsigned addition trap when its mathematical
   --  result does not fit.  Carry is that condition on x86-64, and the
   --  successful edge is the only one that stores the result.
   procedure Unsigned_Add_Uses_Carry_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Add_Uses_Carry_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, b: u8) -> (r: u8) =" & LF
         & "    r = a + b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "addb "),
            "u8 addition uses a byte instruction");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jnc .L1_V"),
            "no carry reaches the successful continuation");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "ud2" & LF & ".L1_V"),
            "carry reaches an explicit trap before the result is stored");
      end;
   end Unsigned_Add_Uses_Carry_To_Trap;

   --  x86-64 reports an unsigned subtraction's borrow in the same carry
   --  flag, so underflow takes the trap edge ordinary `-` requires.
   procedure Unsigned_Subtract_Uses_Borrow_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Subtract_Uses_Borrow_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u16, b: u16) -> (r: u16) =" & LF
         & "    r = a - b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "subw "),
            "u16 subtraction uses a word instruction");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jnc .L1_V"),
            "no borrow reaches the successful continuation");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "ud2" & LF & ".L1_V"),
            "borrow reaches an explicit trap before the result is stored");
      end;
   end Unsigned_Subtract_Uses_Borrow_To_Trap;

   --  Carry does not say whether a signed result is representable.  Signed
   --  arithmetic therefore takes its trap edge from x86-64's overflow flag.
   procedure Signed_Add_Uses_Overflow_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Signed_Add_Uses_Overflow_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i32, b: i32) -> (r: i32) =" & LF
         & "    r = a + b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "addl "),
            "i32 addition uses a long instruction");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jno .L1_V"),
            "no signed overflow reaches the successful continuation");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "jnc .L1_V"),
            "signed addition does not use unsigned carry");
      end;
   end Signed_Add_Uses_Overflow_To_Trap;

   --  isize obtains its width from the target description, while signed
   --  subtraction still uses overflow rather than borrow to decide its edge.
   procedure Signed_Subtract_Follows_The_Target_Width
     (Item : in out Landin.Testing.Context);

   procedure Signed_Subtract_Follows_The_Target_Width
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: isize, b: isize) -> (r: isize) =" & LF
         & "    r = a - b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "subq "),
            "isize subtraction follows the target's 64-bit width");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jno .L1_V"),
            "signed subtraction tests the overflow flag");
      end;
   end Signed_Subtract_Follows_The_Target_Width;

   --  [0330]'s `~` gives its own integer type back and cannot overflow, so
   --  it is one width-specific `not` through the accumulator with no edge.
   procedure Complement_Inverts_Without_A_Trap
     (Item : in out Landin.Testing.Context);

   procedure Complement_Inverts_Without_A_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8) -> (r: u8) =" & LF
         & "    r = ~a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -3(%rbp), %al" & LF
           & HT & "notb %al" & LF
           & HT & "movb %al, -4(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "u8 complement inverts through the accumulator");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "complement has no trap edge");
      end;
   end Complement_Inverts_Without_A_Trap;

   --  Unary minus gives its own integer type back [1890], so negating the
   --  lowest signed value overflows exactly as [0300] describes.  `neg` sets
   --  overflow for precisely that operand, which is the edge to test.
   procedure Signed_Negation_Traps_On_The_Lowest_Value
     (Item : in out Landin.Testing.Context);

   procedure Signed_Negation_Traps_On_The_Lowest_Value
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i8) -> (r: i8) =" & LF
         & "    r = -a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -3(%rbp), %al" & LF
           & HT & "negb %al" & LF
           & HT & "jno .L1_V2" & LF
           & HT & "ud2" & LF
           & ".L1_V2:" & LF
           & HT & "movb %al, -4(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "i8 negation traps before storing an unrepresentable result");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "jnc .L1_V2"),
            "signed negation does not use unsigned carry");
      end;
   end Signed_Negation_Traps_On_The_Lowest_Value;

   --  An unsigned type holds the negation of zero and of nothing else, and
   --  `neg` sets carry for exactly the operands that are not zero.
   procedure Unsigned_Negation_Uses_Carry_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Negation_Uses_Carry_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: usize) -> (r: usize) =" & LF
         & "    r = -a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "negq %rax"),
            "usize negation follows the target's 64-bit width");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "jnc .L1_V2"),
            "unsigned negation tests carry");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "jno .L1_V2"),
            "unsigned negation does not use signed overflow");
      end;
   end Unsigned_Negation_Uses_Carry_To_Trap;

   --  [0340]'s `not` takes a bool and gives one back, and [1870] fixes that
   --  bool at zero or one.  Flipping the low bit is therefore the whole
   --  operation; a width-wide `not` would give 254 for `not false`.
   procedure Logical_Not_Flips_The_One_Byte_Bool
     (Item : in out Landin.Testing.Context);

   procedure Logical_Not_Flips_The_One_Byte_Bool
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: bool) -> (r: bool) =" & LF
         & "    r = not a" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -3(%rbp), %al" & LF
           & HT & "xorb $1, %al" & LF
           & HT & "movb %al, -4(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "logical not flips the bool's low bit alone");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "notb %al"),
            "logical not is not a width-wide complement");
      end;
   end Logical_Not_Flips_The_One_Byte_Bool;

   --  [0330]'s `&`, `^` and `|` give their own integer type back, so each is
   --  one width-specific instruction with no edge and no signed variant.
   procedure Every_Bitwise_Operator_Selects_Its_Instruction
     (Item : in out Landin.Testing.Context);

   procedure Every_Bitwise_Operator_Selects_Its_Instruction
     (Item : in out Landin.Testing.Context)
   is
      type Case_Row is record
         Source      : access constant String;
         Instruction : access constant String;
      end record;

      And_Source : aliased constant String := "&";
      Xor_Source : aliased constant String := "^";
      Or_Source  : aliased constant String := "|";
      And_Text   : aliased constant String := "andl";
      Xor_Text   : aliased constant String := "xorl";
      Or_Text    : aliased constant String := "orl";

      Rows : constant array (1 .. 3) of Case_Row :=
        [(And_Source'Access, And_Text'Access),
         (Xor_Source'Access, Xor_Text'Access),
         (Or_Source'Access, Or_Text'Access)];
   begin
      for Row of Rows loop
         declare
            Work : Landin.Stages.Compilation :=
              Landin.Stages.Create (Landin.Targets.Linux_X86_64);
            Ran  : Natural;
         begin
            Lower
              (Work,
               "f: (a: i32, b: i32) -> (r: i32) =" & LF
               & "    r = a " & Row.Source.all & " b" & LF & "end f" & LF,
               Ran);

            Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

            declare
               Text : constant String := Emitted (Work);
               Expected : constant String :=
                 HT & "movl -28(%rbp), %eax" & LF
                 & HT & Row.Instruction.all & " -24(%rbp), %eax" & LF
                 & HT & "movl %eax, -32(%rbp)" & LF;
            begin
               Landin.Testing.Check
                 (Item, Contains (Text, Expected),
                  Row.Source.all & " emits " & Row.Instruction.all
                  & " and stores immediately");
               Landin.Testing.Check
                 (Item, not Contains (Text, HT & "ud2"),
                  Row.Source.all & " has no trap edge");
            end;
         end;
      end loop;
   end Every_Bitwise_Operator_Selects_Its_Instruction;

   --  [0320] fills with zeros beyond the width for any amount, and x86-64
   --  masks the count instead -- five bits at 32-bit, six at 64 -- so
   --  `1u8 << 40` would shift by 8 on the bare hardware.  The width test is
   --  therefore the compiler's own and not the processor's.
   procedure Unsigned_Shift_Left_Zeroes_Beyond_The_Width
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Shift_Left_Zeroes_Beyond_The_Width
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, s: u8) -> (r: u8) =" & LF
         & "    r = a << s" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -6(%rbp), %al" & LF
           & HT & "cmpb $8, %al" & LF
           & HT & "jb .L1_V5_inrange" & LF
           & HT & "movb $0, -8(%rbp)" & LF
           & HT & "jmp .L1_V5_done" & LF
           & ".L1_V5_inrange:" & LF
           & HT & "movb -6(%rbp), %cl" & LF
           & HT & "movb -7(%rbp), %al" & LF
           & HT & "shlb %cl, %al" & LF
           & HT & "movb %al, -8(%rbp)" & LF
           & ".L1_V5_done:" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "a u8 shift tests its own width before shifting");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "an unsigned amount cannot be negative and needs no trap");
      end;
   end Unsigned_Shift_Left_Zeroes_Beyond_The_Width;

   --  D6 gives the amount the left operand's type, so a signed left operand
   --  admits a negative amount and [1950] leaves the ones the compiler could
   --  not read to the trap.  A signed `>>` is the arithmetic one.
   procedure Signed_Shift_Right_Traps_A_Negative_Amount
     (Item : in out Landin.Testing.Context);

   procedure Signed_Shift_Right_Traps_A_Negative_Amount
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i32, s: i32) -> (r: i32) =" & LF
         & "    r = a >> s" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Guard : constant String :=
           HT & "movl -24(%rbp), %eax" & LF
           & HT & "cmpl $0, %eax" & LF
           & HT & "jge .L1_V5_nonnegative" & LF
           & HT & "ud2" & LF
           & ".L1_V5_nonnegative:" & LF
           & HT & "cmpl $32, %eax" & LF
           & HT & "jb .L1_V5_inrange" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Guard),
            "a negative amount traps before the width is tested");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "sarl %cl, %eax"),
            "a signed shift right is the arithmetic one");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "shrl %cl, %eax"),
            "a signed shift right is not the logical one");
      end;
   end Signed_Shift_Right_Traps_A_Negative_Amount;

   --  D13 settles the sentence [0320] left open: an amount at or past the
   --  width gives zero on every shift, and a signed `>>` is not the
   --  exception.  The width itself comes from the target description.
   procedure A_Signed_Shift_Beyond_The_Width_Is_Zero
     (Item : in out Landin.Testing.Context);

   procedure A_Signed_Shift_Beyond_The_Width_Is_Zero
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: isize, s: isize) -> (r: isize) =" & LF
         & "    r = a >> s" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Beyond : constant String :=
           HT & "cmpq $64, %rax" & LF
           & HT & "jb .L1_V5_inrange" & LF
           & HT & "movq $0, -64(%rbp)" & LF
           & HT & "jmp .L1_V5_done" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Beyond),
            "isize takes its width from the target and zeroes beyond it");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "sarq %cl, %rax"),
            "an amount below the width still keeps the sign");
      end;
   end A_Signed_Shift_Beyond_The_Width_Is_Zero;

   --  x86-64 divides its implicit full-width dividend.  An unknown zero
   --  divisor therefore reaches Landin's explicit trap before `div`, while a
   --  valid u8 dividend has its high byte cleared and stores the quotient.
   procedure Unsigned_Divide_Guards_Zero_And_Stores_The_Quotient
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Divide_Guards_Zero_And_Stores_The_Quotient
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, b: u8) -> (r: u8) =" & LF
         & "    r = a / b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Guard : constant String :=
           HT & "cmpb $0, -6(%rbp)" & LF
           & HT & "jne .L1_V5_nonzero" & LF
           & HT & "ud2" & LF
           & ".L1_V5_nonzero:" & LF;
         Operation : constant String :=
           HT & "movb -7(%rbp), %al" & LF
           & HT & "movb $0, %ah" & LF
           & HT & "divb -6(%rbp)" & LF
           & HT & "movb %al, -8(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Guard),
            "a runtime zero divisor reaches an explicit trap");
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "u8 division clears the high dividend and stores its quotient");
      end;
   end Unsigned_Divide_Guards_Zero_And_Stores_The_Quotient;

   --  Signed division has a second trap case: the minimum value divided by
   --  minus one.  It is recognized before `idiv`, rather than inheriting the
   --  processor's incidental divide fault, and a valid byte is sign-extended.
   procedure Signed_Divide_Guards_Overflow_And_Truncates
     (Item : in out Landin.Testing.Context);

   procedure Signed_Divide_Guards_Overflow_And_Truncates
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i8, b: i8) -> (r: i8) =" & LF
         & "    r = a / b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Overflow : constant String :=
           HT & "cmpb $-1, -6(%rbp)" & LF
           & HT & "jne .L1_V5_divide" & LF
           & HT & "movabsq $128, %rax" & LF
           & HT & "cmpb -7(%rbp), %al" & LF
           & HT & "jne .L1_V5_divide" & LF
           & HT & "ud2" & LF;
         Operation : constant String :=
           ".L1_V5_divide:" & LF
           & HT & "movb -7(%rbp), %al" & LF
           & HT & "cbtw" & LF
           & HT & "idivb -6(%rbp)" & LF
           & HT & "movb %al, -8(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Overflow),
            "signed minimum divided by minus one reaches an explicit trap");
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "i8 division sign-extends its dividend and stores the quotient");
      end;
   end Signed_Divide_Guards_Overflow_And_Truncates;

   --  The signed minimum modulo minus one is zero in Landin.  Since `idiv`
   --  would fault for that operand pair, remainder recognizes it as a
   --  successful zero result and otherwise stores the high half's remainder.
   procedure Signed_Remainder_Handles_Minimum_Modulo_Minus_One
     (Item : in out Landin.Testing.Context);

   procedure Signed_Remainder_Handles_Minimum_Modulo_Minus_One
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i8, b: i8) -> (r: i8) =" & LF
         & "    r = a % b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Special : constant String :=
           HT & "cmpb $-1, -6(%rbp)" & LF
           & HT & "jne .L1_V5_divide" & LF
           & HT & "movabsq $128, %rax" & LF
           & HT & "cmpb -7(%rbp), %al" & LF
           & HT & "jne .L1_V5_divide" & LF
           & HT & "movb $0, -8(%rbp)" & LF
           & HT & "jmp .L1_V5_done" & LF;
         Operation : constant String :=
           ".L1_V5_divide:" & LF
           & HT & "movb -7(%rbp), %al" & LF
           & HT & "cbtw" & LF
           & HT & "idivb -6(%rbp)" & LF
           & HT & "movb %ah, -8(%rbp)" & LF
           & ".L1_V5_done:" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Special),
            "signed minimum modulo minus one stores zero without dividing");
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "an ordinary i8 remainder comes from its implicit register");
      end;
   end Signed_Remainder_Handles_Minimum_Modulo_Minus_One;

   --  One-operand `mul` forms a full unsigned product in the implicit
   --  accumulator pair.  Carry is clear exactly when its high half is zero,
   --  so the successful edge alone may store the low byte.
   procedure Unsigned_Multiply_Uses_The_Full_Product
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_Multiply_Uses_The_Full_Product
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, b: u8) -> (r: u8) =" & LF
         & "    r = a * b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Operation : constant String :=
           HT & "movb -7(%rbp), %al" & LF
           & HT & "mulb -6(%rbp)" & LF
           & HT & "jnc .L1_V";
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "u8 multiply checks the full unsigned product immediately");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "ud2" & LF & ".L1_V"),
            "unsigned overflow reaches an explicit trap");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "movb %al, -8(%rbp)"),
            "only the successful edge stores the low product");
      end;
   end Unsigned_Multiply_Uses_The_Full_Product;

   --  One-operand `imul` reports whether the full signed product is the sign
   --  extension of its low half.  Its overflow flag therefore decides whether
   --  the low byte is representable, independently of unsigned carry.
   procedure Signed_Multiply_Uses_Overflow_To_Trap
     (Item : in out Landin.Testing.Context);

   procedure Signed_Multiply_Uses_Overflow_To_Trap
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i8, b: i8) -> (r: i8) =" & LF
         & "    r = a * b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Operation : constant String :=
           HT & "movb -7(%rbp), %al" & LF
           & HT & "imulb -6(%rbp)" & LF
           & HT & "jno .L1_V";
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Operation),
            "i8 multiply tests signed overflow immediately");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "jnc .L1_V"),
            "signed multiply does not use unsigned carry");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "ud2" & LF & ".L1_V"),
            "signed overflow reaches an explicit trap");
      end;
   end Signed_Multiply_Uses_Overflow_To_Trap;

   --  [0300]'s wrapping multiply keeps the accumulator's low target-width
   --  half.  The full product may overflow, but no flag or trap edge is read.
   procedure Wrapping_Multiply_Keeps_The_Low_Product
     (Item : in out Landin.Testing.Context);

   procedure Wrapping_Multiply_Keeps_The_Low_Product
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: isize, b: isize) -> (r: isize) =" & LF
         & "    r = a *% b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movq -56(%rbp), %rax" & LF
           & HT & "imulq -48(%rbp)" & LF
           & HT & "movq %rax, -64(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "wrapping isize multiply stores the low target-width product");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "wrapping multiply has no trap edge");
      end;
   end Wrapping_Multiply_Keeps_The_Low_Product;

   --  [0300]'s wrapping add keeps the low byte and ignores carry.  With no
   --  checked operation in this routine, no trap edge belongs in its text.
   procedure Wrapping_Add_Ignores_Overflow
     (Item : in out Landin.Testing.Context);

   procedure Wrapping_Add_Ignores_Overflow
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u8, b: u8) -> (r: u8) =" & LF
         & "    r = a +% b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movb -7(%rbp), %al" & LF
           & HT & "addb -6(%rbp), %al" & LF
           & HT & "movb %al, -8(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "wrapping u8 addition stores the low byte immediately");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "wrapping addition has no trap edge");
      end;
   end Wrapping_Add_Ignores_Overflow;

   --  A target-width wrapping result follows the target rather than the host,
   --  and subtraction likewise stores immediately without inspecting flags.
   procedure Wrapping_Subtract_Follows_The_Target_Width
     (Item : in out Landin.Testing.Context);

   procedure Wrapping_Subtract_Follows_The_Target_Width
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: isize, b: isize) -> (r: isize) =" & LF
         & "    r = a -% b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movq -56(%rbp), %rax" & LF
           & HT & "subq -48(%rbp), %rax" & LF
           & HT & "movq %rax, -64(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "wrapping isize subtraction follows the target width");
         Landin.Testing.Check
           (Item, not Contains (Text, HT & "ud2"),
            "wrapping subtraction has no trap edge");
      end;
   end Wrapping_Subtract_Follows_The_Target_Width;

   --  AT&T's compare writes no destination, but its operand order still
   --  matters: `cmp right, left` sets flags for left minus right.  A signed
   --  less-than then materializes [1890]'s one-byte bool from those flags.
   procedure Signed_Less_Than_Compares_Left_With_Right
     (Item : in out Landin.Testing.Context);

   procedure Signed_Less_Than_Compares_Left_With_Right
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i32, b: i32) -> (r: bool) =" & LF
         & "    r = a < b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
         Expected : constant String :=
           HT & "movl -28(%rbp), %eax" & LF
           & HT & "cmpl -24(%rbp), %eax" & LF
           & HT & "setl %al" & LF
           & HT & "movb %al, -29(%rbp)" & LF;
      begin
         Landin.Testing.Check
           (Item, Contains (Text, Expected),
            "signed less-than compares left minus right and stores its bool");
      end;
   end Signed_Less_Than_Compares_Left_With_Right;

   --  Equality ignores signedness, while the four ordered relations each
   --  have their own signed condition.  Pin the complete [1820] comparison
   --  level so no two source operators quietly become one machine verdict.
   procedure Every_Signed_Comparison_Selects_Its_Condition
     (Item : in out Landin.Testing.Context);

   procedure Every_Signed_Comparison_Selects_Its_Condition
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: i16, b: i16) -> (r: bool) =" & LF
         & "    equal: bool = a == b" & LF
         & "    unequal: bool = a <> b" & LF
         & "    less: bool = a < b" & LF
         & "    at_most: bool = a <= b" & LF
         & "    greater: bool = a > b" & LF
         & "    r = a >= b" & LF
         & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "sete %al"),
            "equality uses the equal condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setne %al"),
            "inequality uses the not-equal condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setl %al"),
            "signed less-than uses the less condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setle %al"),
            "signed less-or-equal uses the at-most condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setg %al"),
            "signed greater-than uses the greater condition");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setge %al"),
            "signed greater-or-equal uses the at-least condition");
      end;
   end Every_Signed_Comparison_Selects_Its_Condition;

   --  Unsigned order is below/above rather than signed less/greater.  bool
   --  shares those conditions over [1870]'s zero and one, and still compares
   --  at its own one-byte width rather than the bool result choosing a width.
   procedure Unsigned_And_Bool_Comparisons_Use_Their_Conditions
     (Item : in out Landin.Testing.Context);

   procedure Unsigned_And_Bool_Comparisons_Use_Their_Conditions
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      Lower
        (Work,
         "f: (a: u64, b: u64) -> (r: bool) =" & LF
         & "    below: bool = a < b" & LF
         & "    at_most: bool = a <= b" & LF
         & "    above: bool = a > b" & LF
         & "    r = a >= b" & LF
         & "end f" & LF
         & "g: (a: bool, b: bool) -> (r: bool) =" & LF
         & "    r = a < b" & LF
         & "end g" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Text : constant String := Emitted (Work);
      begin
         Landin.Testing.Check
           (Item, Contains (Text, HT & "cmpq "),
            "u64 operands select a quadword comparison");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setb %al"),
            "unsigned less-than uses below");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setbe %al"),
            "unsigned less-or-equal uses below-or-equal");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "seta %al"),
            "unsigned greater-than uses above");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "setae %al"),
            "unsigned greater-or-equal uses above-or-equal");
         Landin.Testing.Check
           (Item, Contains (Text, HT & "cmpb "),
            "bool operands select a byte comparison");
      end;
   end Unsigned_And_Bool_Comparisons_Use_Their_Conditions;

   ------------------------------------------------------------------
   --  The frame
   ------------------------------------------------------------------

   --  A cell starts at a distance that is a multiple of its alignment,
   --  so the address it names is aligned and not merely reached by an
   --  aligned count.
   procedure Every_Cell_Is_Aligned_Below_The_Frame_Pointer
     (Item : in out Landin.Testing.Context);

   procedure Every_Cell_Is_Aligned_Below_The_Frame_Pointer
     (Item : in out Landin.Testing.Context)
   is
      Work : Landin.Stages.Compilation :=
        Landin.Stages.Create (Landin.Targets.Linux_X86_64);
      Ran  : Natural;
   begin
      --  A byte, then something eight wide: the second has to be pushed
      --  past the first rather than laid beside it.
      Lower
        (Work,
         "f: (a: u8, b: u64) -> (r: u64) =" & LF
         & "    r = b" & LF & "end f" & LF,
         Ran);

      Landin.Testing.Check_Equal (Item, Ran, 4, "four stages ran");

      declare
         Unit   : IR.Unit renames Landin.Stages.Code (Work).all;
         One    : constant IR.Item_Id := 1;
         Layout : constant Landin.Backend.Frame :=
           Landin.Backend.Laid_Out
             (Unit, One, Landin.Stages.Target (Work));
         Sound  : Boolean := True;
      begin
         for Which in 1 .. IR.Slot_Count (Unit, One) loop
            declare
               Slot : constant IR.Slot_Id := IR.Slot_Id (Which);
               Wide : constant Landin.Targets.Scalar_Size :=
                 Landin.Backend.Size_Of
                   (IR.Type_Of (Unit, One, Slot),
                    Landin.Stages.Target (Work));
               Where : constant Landin.Targets.Byte_Count :=
                 Landin.Backend.Slot_Offset (Layout, Slot);
               Needs : constant Landin.Targets.Byte_Alignment :=
                 Landin.Targets.Alignment_Of
                   (Landin.Stages.Target (Work), Wide);
            begin
               if Where mod Landin.Targets.Byte_Count (Needs) /= 0
                 or else Where
                         < Landin.Targets.Byte_Count
                             (Landin.Targets.Bytes (Wide))
               then
                  Sound := False;
               end if;
            end;
         end loop;

         Landin.Testing.Check
           (Item, Sound, "every slot's cell is aligned and fits below it");
         Landin.Testing.Check
           (Item,
            Landin.Backend.Extent (Layout)
              mod Landin.Targets.Byte_Count
                    (Landin.Targets.Stack_Alignment
                       (Landin.Stages.Target (Work)))
              = 0,
            "the frame leaves the stack as aligned as it found it");
      end;
   end Every_Cell_Is_Aligned_Below_The_Frame_Pointer;

   --  Nothing outside Landin.Targets may ask the host how wide a pointer
   --  is, so the same item laid out against a 32-bit description gives a
   --  usize cell four bytes on this 64-bit host.
   procedure A_Frame_Follows_The_Target_And_Not_The_Host
     (Item : in out Landin.Testing.Context);

   procedure A_Frame_Follows_The_Target_And_Not_The_Host
     (Item : in out Landin.Testing.Context) is
   begin
      Landin.Testing.Check
        (Item,
         Landin.Backend.Size_Of
           (Landin.Types.Usize, Landin.Targets.Synthetic_32)
         = Landin.Targets.Byte_4,
         "usize is four bytes on a 32-bit description");
      Landin.Testing.Check
        (Item,
         Landin.Backend.Size_Of
           (Landin.Types.Usize, Landin.Targets.Linux_X86_64)
         = Landin.Targets.Byte_8,
         "and eight on a 64-bit one");
      --  [0150]: outside a packed struct a one-bit field occupies the
      --  next machine width, which is a byte.
      Landin.Testing.Check
        (Item,
         Landin.Backend.Size_Of
           (Landin.Types.Bool, Landin.Targets.Linux_X86_64)
         = Landin.Targets.Byte_1,
         "a bool occupies the next machine width above one bit");
   end A_Frame_Follows_The_Target_And_Not_The_Host;

   procedure Register (Into : in out Landin.Testing.Registry) is
   begin
      Landin.Testing.Register
        (Into, "backend", "a constant return emits its whole frame",
         A_Constant_Return_Emits_Its_Whole_Frame'Access);
      Landin.Testing.Register
        (Into, "backend", "only a public routine is made global",
         Only_A_Public_Routine_Is_Made_Global'Access);
      Landin.Testing.Register
        (Into, "backend", "a parameter is stored from its register",
         A_Parameter_Is_Stored_From_Its_Register'Access);
      Landin.Testing.Register
        (Into, "backend", "a branch names both of its edges",
         A_Branch_Names_Both_Of_Its_Edges'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned add uses carry to trap",
         Unsigned_Add_Uses_Carry_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned subtract uses borrow to trap",
         Unsigned_Subtract_Uses_Borrow_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "signed add uses overflow to trap",
         Signed_Add_Uses_Overflow_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "signed subtract follows the target width",
         Signed_Subtract_Follows_The_Target_Width'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned shift left zeroes beyond the width",
         Unsigned_Shift_Left_Zeroes_Beyond_The_Width'Access);
      Landin.Testing.Register
        (Into, "backend", "signed shift right traps a negative amount",
         Signed_Shift_Right_Traps_A_Negative_Amount'Access);
      Landin.Testing.Register
        (Into, "backend", "a signed shift beyond the width is zero",
         A_Signed_Shift_Beyond_The_Width_Is_Zero'Access);
      Landin.Testing.Register
        (Into, "backend", "complement inverts without a trap",
         Complement_Inverts_Without_A_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "signed negation traps on the lowest value",
         Signed_Negation_Traps_On_The_Lowest_Value'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned negation uses carry to trap",
         Unsigned_Negation_Uses_Carry_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "logical not flips the one byte bool",
         Logical_Not_Flips_The_One_Byte_Bool'Access);
      Landin.Testing.Register
        (Into, "backend", "every bitwise operator selects its instruction",
         Every_Bitwise_Operator_Selects_Its_Instruction'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned divide guards zero and stores quotient",
         Unsigned_Divide_Guards_Zero_And_Stores_The_Quotient'Access);
      Landin.Testing.Register
        (Into, "backend", "signed divide guards overflow and truncates",
         Signed_Divide_Guards_Overflow_And_Truncates'Access);
      Landin.Testing.Register
        (Into, "backend", "signed remainder handles minimum modulo minus one",
         Signed_Remainder_Handles_Minimum_Modulo_Minus_One'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned multiply uses the full product",
         Unsigned_Multiply_Uses_The_Full_Product'Access);
      Landin.Testing.Register
        (Into, "backend", "signed multiply uses overflow to trap",
         Signed_Multiply_Uses_Overflow_To_Trap'Access);
      Landin.Testing.Register
        (Into, "backend", "wrapping multiply keeps the low product",
         Wrapping_Multiply_Keeps_The_Low_Product'Access);
      Landin.Testing.Register
        (Into, "backend", "wrapping add ignores overflow",
         Wrapping_Add_Ignores_Overflow'Access);
      Landin.Testing.Register
        (Into, "backend", "wrapping subtract follows the target width",
         Wrapping_Subtract_Follows_The_Target_Width'Access);
      Landin.Testing.Register
        (Into, "backend", "signed less-than compares left with right",
         Signed_Less_Than_Compares_Left_With_Right'Access);
      Landin.Testing.Register
        (Into, "backend", "every signed comparison selects its condition",
         Every_Signed_Comparison_Selects_Its_Condition'Access);
      Landin.Testing.Register
        (Into, "backend", "unsigned and bool comparisons use their conditions",
         Unsigned_And_Bool_Comparisons_Use_Their_Conditions'Access);
      Landin.Testing.Register
        (Into, "backend", "every cell is aligned below the frame pointer",
         Every_Cell_Is_Aligned_Below_The_Frame_Pointer'Access);
      Landin.Testing.Register
        (Into, "backend", "a frame follows the target and not the host",
         A_Frame_Follows_The_Target_And_Not_The_Host'Access);
   end Register;

end Landin.Tests.Backend_Suite;
