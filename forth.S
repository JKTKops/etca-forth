;; ----------------------------------------------------------------------------------------- ;;
;;    _____   _____   _____       __             _____   _____   _____   _____   __   __     ;;
;;   |   __| |_   _| |   __|     /  \           |   __| |  _  | |  _  | |_   _| |  | |  |    ;;
;;   |  |__    | |   |  |       / /\ \          |  |__  | | | | | |_| |   | |   |  |_|  |    ;;
;;   |   __|   | |   |  |      / /__\ \         |   __| | | | | |    _|   | |   |   _   |    ;;
;;   |  |__    | |   |  |__   / ______ \        |  |    | |_| | | |\ \    | |   |  | |  |    ;;
;;   |_____|   |_|   |_____| /_/      \_\       |__|    |_____| |_| \_\   |_|   |__| |__|    ;;
;;                                                                                           ;;
;; ----------------------------------------------------------------------------------------- ;;


/* Version H0.0.1
This project is a demonstration of using Forth as a stepping stone to bootstrap out of assembly
on a new system (ETCa) as fast as possible. As a proof of concept, it is extension-heavy. We
allow it to use pretty much every extension. It is intended for a system running in real
32-bit pointer mode. The H in the version number is for 'heavy,' we may produce 'light' versions
in the future.

This file is intended to be viewed in a pane at least 100 columns wide.
*/

/* Adjust this for the input MMIO. See Comment: Parsing Input. */
#define INPUT_STREAM 1

/* Basic overview of Forth
Programs are sequences of ``words," essentially just tokens separated by whitespace. This system
interpreters characters 0x0A and 0x20 ('\n' and ' ') as whitespace, and 0x00 as the end-of-input.
Everything else is treated as printable, which more or less matches the Console component in TC.

Forth code included in comments will be surrounded by backticks, such as `CODE`. Backticks are
valid characters in Forth words, but we won't use them to avoid confusion.

Words are understood as they are read; there is no separate parsing or analysis phases. The words
manipulate two stacks (in a complete implementation of the full standard, they manipulate four).
The ``main" stack is the ``Data Stack." For example, the program `0 5` pushes the value 0 to the
data stack, then pushes the value 5. `+` pops two values, then pushes their sum. `DUP` duplicates
the top value of the stack, `DROP` throws it away, etc.

The other stack is the ``Return Stack." It is used to store return addresses in much the same way
as the regular program stack pointed to by %sp, but as we will see, the stored addresses do not
point to ETCa machine code. (And, in this program, %sp points at the data stack!)

Since words are understood only as they are read, what happens if we read a user-defined word
that we've already processed the definition for? We can't read the text again (that violates the
single-pass rule). The solution: JIT compilation. Using a shockingly simple system called
``Direct-Threaded Code," we compile definitions as they are read and later simply execute the
compiled code. When a user word calls another user word, the return stack is required. This means
any words that manipulate the return stack need to be handled with care - *calling* such words
would put a return address on top of the return stack, which is not what the word intended to
manipulate! We will solve this problem below.

A Forth system starts in ``interpretation mode." Writing `5 5 + .` would print 10 if all of those
words were implemented. `.` is tricky, so we implement it in Forth itself later. However, the
point is that reading those words makes things happen _immediately_: no compilation. The words
are called as they are read.

The primitive word `:` is used to create definitions. It reads the next word from the input and
creates a new entry for it in the ``dictionary." The dictionary has all known words in it,
including their implementations (more on that in the next section). Following words are compiled
into the definition. The definition is terminated by `;`, another primitive word. For example, the
code `: DOUBLE DUP + ;` defines a word named DOUBLE which doubles the top of the stack by adding
it to itself. This word is actually defined in this file as `2*` and is a somewhat instructive
example of a primitive word.

Once a word is defined, it can be called just like any other word.
*/

/* Stacks
The data stack will be the regular stack pointed to by %sp (DSP). Instructions push and pop will
use and modify this pointer. But ETCa actually supports pushing and popping with _any_ pointer
register with the ASP extension. The syntax changes rather drastically though. So we'll use
ASP to implement the return stack, and have it pointed to by the ``return stack pointer" RSP.
We can use macros to define nicer names for pushing and popping from the return stack.
*/

#define DSP %spd
#define RSP %rd5

        .macro PUSHRSP src
        movd    [--RSP], \src
        .endm
        .macro POPRSP dst
        movd    \dst, [RSP++]
        .endm

/* Direct-Threaded Code
The code for every dictionary entry is contained in a data structure called a ``thread." Threads
are split into a ``header", ``code field", and ``payload" or ``parameter field." The term ``thread"
will often be overloaded to refer to just the payload. The thread for DOUBLE, defined above, would
look like this (this header structure is similar to that of JonesForth):

  +----------+----------+---+---+---+---+---+---+---+---+------------+-----+---+------+
  | LINK PTR | FLGS+LEN | D | O | U | B | L | E | 0 | 0 | call ENTER | DUP | + | EXIT |
  +----------+----------+---+---+---+---+---+---+---+---+------------+-----+---+------+

The breakdown is as follows:
  * LINK PTR: pointer to the previous dictionary entry, forming a linked list.
  * FLGS+LEN: one byte containing the length (up to 32) of the name, and 3 flags about the entry.
  * The name, plus padding to align it to a 4-byte boundary.
  * A call sequence to jump to the thread's ``entry code." All dictionary entries have a code
    field, but all threads _specifically_ will invoke the ENTER routine. Other entries may for
    example simply inline a machine code routine to do their job.
  * The addresses of the code fields of DUP, +, and EXIT (all of which have dictionary entries,
    but none of which are threads - hence why it's important that all entries have a code field!)

Putting machine code directly into the code field, rather than an address pointing to the machine
code, is the distinguishing feature of _direct_ threaded code as opposed to other kinds of
threaded code.
*/

/* The thread ``interpreter"
**This refers to a different kind of interpretation than the user input-output loop!**

The point of this kind of ``interpreter" is that the Thread structure defined above does not
actually contain any information about how to execute the sequence of addresses DUP + EXIT.
They aren't jump/call instructions, or any other form of executable code. They are literally
just addresses. So we need some kind of interpreter to figure out what to actually do with them.

The reason we put ``interpreter" in quotes is because it's not an interpreter the way that the JVM
or CPython are ``interpreters." Those interpreters have full control of the entire system, and
modify ``virtual machine state" to make each specified operation happen. We don't have any kind
of bytecode to specify operations! All we need to do is make sure we invoke the entry code for
each entry in the thread, and that entry code is _machine code_ which will make things happen
(possibly by switching the current thread of execution to a new thread, or possibly just by
executing some machine code given as a primitive operation). The entry code of a thread needs to
make sure that this happens, so all threads share an entry code routine called ENTER.

At any given time, we're executing some word of some thread somewhere. Even the top-level
interaction loop will be implemented as a Forth thread that just jumps back to its own start.
We pin a register to keep track of where we are and call it the ``instruction pointer" even
though it's not the ETCa instruction pointer. This will be %rd4.
*/

#define IP %rd4

/* ``interpreter" continued
The register %rd4 points at all times to the cell (4-byte unit) after the one containing the
address of the entry currently executing (normally, ``the next address to execute," but not
if the current one is the end of a thread). That was a lot of words; here's a diagram of between
the steps of DOUBLE:

         +---------------+
         | LINK/FLGS/LEN |
         +---------------+
         |  name DOUBLE  |
         +---------------+
         |  call ENTER   |
         +---------------+
         |      DUP      |
         +---------------+
         |       +       <-------- currently executing this
         +---------------+
   IP -> |      EXIT     |
         +---------------+

None of the words in DOUBLE are themselves threads, they are all primitive. So how do they move
on to the next word when they're done? Simple: get the address currently pointed to by IP, which
itself points at the next word's codeword; increment IP; then jump to the next word's codeword.
This fetch-and-increment operation is the same as pop instruction - and as we've seen, ETCa can
``pop" with any register as the pointer operand. This whole sequence is canonically called NEXT,
and every word (even threads, via EXIT), will end by executing it. It's important that it's fast!

On a lighter ETCa that doesn't support the ASP extension, it can be worked around with a ld
and add instruction, but if we have ASP, we should use it:
*/

        .macro NEXT
        mov     %rd0, [IP++]
        jmp     %rd0
        .endm

/* ``Pinned Registers"
The technique of fixing specific registers for specific purposes throughout the whole file is
called ``register pinning." Also, doing anything ``throughout the whole file" is called
``globally." Why globally pin some registers? Because we need those values extremely, extremely
frequently, and saving those values elsewhere would be quite costly. We've already seen 3 pinned
registers above: IP, DSP, and RSP are all pinned registers. We will also pin %rd3 to the
``top of stack" - we manipulate the top of the stack with pretty much every word, so keeping it
in a register speeds up some words significantly.

This leaves %r0, %r1, %r2, and %r7 free for temporary use. %r7 is kept free because it is clobbered
by any call instructions. We don't use call instructions often (see below: Returning from Forth
Words), but they are used to speed up `DOES>`. Additionally, with REX, we have access
to additional registers %r8-%r15, which may be used if needed. We will pin one of these, %r8,
to always hold the address of ENTER.

ENTER is used a lot - not quite as often as NEXT, but it's
important that we can jump to it very quickly. On many systems (including both of the systems being
considered as targets for this) an indirect register jump is (significantly) faster than the
alternative absolute jump instruction from EXOP, and takes less space.

If REX is not available, then the sequence ``mov %rd0, [target]; jmp %rd0" works in place of
pinning %r8. However, it is very difficult to emit the target addresses in the JIT compiler without
shift operations from EXOP, so a different alternative may be needed.
*/

#define TOS  %r3
#define ENTER_PIN %rd8

/* The Interpreter and The Return Stack [based on JonesForth comment]
Words defined in Forth need their codeword to give them a bit of a start. Otherwise, IP is
pointing into the thread that called them, instead of into their own thread. So it's the job of
their codeword to set up IP to point at the right place - and make sure the old one can be
restored later. And of course, this is why we have a return stack!

ENTER's job is to save the previous IP, and set the IP to the first cell of the new thread's
parameter field (that is, the new thread's ``thread", but that's confusing). NEXT always jumps
through %rd0, so we know that the new thread's code field address is in %rd0. Its parameter field
begins 4 bytes after that (3 bytes for the jmp %rd8 and one byte of alignment padding). Finally,
it runs NEXT to invoke the new thread.
*/

; this is the first code in the file, and neither of the target systems have smart executable
; loaders. So rather than relying on _start being the entrypoint to the code, we ensure it
; is the first code in the file and jumps to whatever should actually be first. This jump should
; be short (just over ENTER).

        .text
        .globl _start
_start: jmp main

        .text
        ; .p2align 2      ; Both target systems can fetch stall, but 2mod8 is already good enough.
                          ; So this can be commented out for now.
ENTER:
        PUSHRSP IP        ; save old IP
        addd    %rd0, 4   ; PFA = CFA + 4
        movd    IP, %rd0  ; IP = PFA
        NEXT

/* previous comment continued
Copying from JonesForth, let's be absolutely clear about how ENTER works. For this, let's use an
example Forth word that calls another Forth word: `: QUADRUPLE DOUBLE DOUBLE ;`. Starting here:

          +------------------+
          | QUADRUPLE        |
          +------------------+
          | codeword         |                +-------------------+
          +------------------+                | DOUBLE            |
          | addr of DOUBLE  ----------------> +-------------------+
          +------------------+        %rd0 -> | jmp ENTER_PIN     |
    IP -> | addr of DOUBLE   |                +-------------------+
          +------------------+                | addr of DUP       |
          | addr of EXIT     |                +-------------------+
          +------------------+                |        ...        |

We've just executed jmp %rd0 so the next thing to execute is jmp ENTER_PIN. This will jump to the
(constant) address of ENTER being held in %rd8 as described above. ENTER will save IP, and figure
out the new IP:

          +------------------+
          | QUADRUPLE        |
          +------------------+
          | codeword         |                +-------------------+
          +------------------+                | DOUBLE            |
          | addr of DOUBLE  ----------------> +-------------------+
          +------------------+        %rd0 -> | jmp ENTER_PIN     |
 (RSP) -> | addr of DOUBLE   |        + 4 =   +-------------------+
          +------------------+          IP -> | addr of DUP       |
          | addr of EXIT     |                +-------------------+
          +------------------+                |        ...        |

Then we run NEXT, which will increment IP and call DUP.

The EXIT word does the opposite: restore IP via POPRSP, then run NEXT. But we can't define it
just yet, because EXIT is a forth word, and so it needs a header and soforth. We aren't ready for
that just yet.
*/

/* Starting Up

When the program starts, it needs to set up its stacks and other such things. But then we want
to get into Forth code. Of course most of the Forth primitives are implemented in assembly, but
the less time we are mixing typical function calls with Forth words, the better.

The forth word QUIT doesn't actually quit the interpreter. It resets the return stack and starts
back at the top of the interpreter loop. It's called QUIT because using it from another Forth word
has the effect of quitting the current operation(s).

Each of the stacks is initialized with 256 cells (1024 bytes), but this is essentially configurable.
Most users of Forth will tell you that 256 cells is incredibly excessive. But we have the memory, so.
*/

; assume addresses 0x00000000-0x00000020 are memory mapped. Put the return stack at 0x400, so it's
; actually 248 cells, but that's... so... many.
; Other space in lower ram (<0x80000000) can be used for memory-mapping a console, buffers, or
; other similar ideas. Upper RAM is used for storing the dictionary. Lots of things are possible.
; Note that the dictionary _actually_ begins within this binary. But where the next dictionary
; entries (or other data) will be allocated is controlled by Forth's global HERE variable, so
; we will initialize that to the first cell of upper RAM.
; To change where buffers are being allocated, adjust the "ram" section in the linker script.
.set RETURN_STACK_BOTTOM, 0x400
.set DATA_STACK_BOTTOM,   0x100 ; 0x800
.set DICTIONARY_START,    0x80000000
; linker script is set to start RAM at 0x800.

        .text
        .p2align 3
main:                           ; TODO ext/ft check
        mov     %rx0, 2
        mov     %address_mode, %rx0     ; switch to real32

        mov     DSP, DATA_STACK_BOTTOM
        mov     RSP, RETURN_STACK_BOTTOM
        movd    [var_HERE], DICTIONARY_START
        movd    [var_LATEST], init_LATEST
        mov     ENTER_PIN, ENTER

        mov     IP, cold_start
        NEXT

        .section .rodata
cold_start:
        .int QUIT


/* Defining Built-In Words

Recall the layout of a user-defined word given above (with a bit more precision here).

    previous entry                                        code field of DUP
     ^                                                     ^
     |                                                     |
  +--|---+---+---+---+---+---+---+---+---+-----------+---+-|---+---+------+
  | LINK | 6 | D | O | U | B | L | E | 0 | call %rd8 | 0 | DUP | + | EXIT |
  +------+---+---+---+---+---+---+---+---+-----------+---+-----+---+------+
     ^    len                         pad             pad
     |                              1 byte          2 bytes
    LINK in next entry

It's useful to define such words in this file, when something would be difficult or too much
in assembly. But we can't just write ": DOUBLE DUP + ;" yet, because an ETCa assembler would
have no clue what that means. Instead, we have to lay it out ourselves. For this entry, that
would look like this:

        .p2align 2
        .int <link to previous word>
        .byte 6
        .ascii "DOUBLE"
        .byte 0
DOUBLE: call ENTER_PIN
        .p2align 2
        .int DUP
        .int PLUS
        .int EXIT

That's obviously very tedious, so we instead define a macro to create all of the repeated
stuff for us. We also want a macro for defining _primitive_ words, which are implemented in
assembly - that simply creates a header and a label, but stops before emitting the call to ENTER.

*/

        ; flags: used to implement compile-time words and smudging
        .set F_IMMED,0x80
        .set F_SMUDGE,0x40
        .set F_LENMASK,0x1F

        ; chain of LINK pointers ends with 0, and will be maintained using the local
        ; label 1: - this allows each word to get the link to the previous word using
        ; 1b. However the first word will therefore have to be created manually to put
        ; a 0 in the link field. We can't use .set to maintain the chain of links because
        ; etca-as does relaxation.
        ; Because local label 1 is being used for this, it cannot be used for other things.

        .macro defcode name, namelen, flags=0, label
        .section .rodata
        .p2align 2
        .int 1b-4 ; pointer to previous link; if we put 1: here then it would be to self!
1:      
        .byte \flags+\namelen
        .ascii "\name"
        .p2align 2
        .globl \label
\label :
        .endm

        .macro defword name, namelen, flags=0, label
        defcode "\name", \namelen, \flags, \label
        jmp ENTER_PIN
        .p2align 2
        .endm


;; Finally, we can start implementing some basic Forth primitives.
;; We have to make the first header by hand to fill the link correctly.

        .section .rodata
        .p2align 2
        .int 0
1:      
        .byte 4
        .ascii "DROP"
        .p2align 2
        .globl DROP
DROP:
        popd    TOS
        NEXT

/* Returning from Forth Words
We want EXIT to be early in the dictionary just to save a bit of time when searching, because
it is referred to very rarely (most words get their reference to `EXIT` inserted by `;`).
EXIT handles returning from a Forth word. A few comments ago (with a diagram), we said it has
to restore IP from the return stack and then run NEXT. Simple enough!
*/

        defcode "EXIT",4,,EXIT
        POPRSP  IP
        NEXT

/* Primitive Operations with Parameters
In threaded code, how are we supposed to implement an operation like `15`, which just pushes the
number 15 on the stack? The only thing we can put in the thread is the address of a forth word
(whether defined in assembly or not) and we can't possibly make an entry for every single 32-bit
number. So what do? The answer: turn `: 5+ 5 + ;` into this entry:

   +------+---+-----+-----+---+-----------+---+-----+---+---+------+
   | LINK | 2 | '5' | '+' | 0 | call %rd8 | 0 | LIT | 5 | + | EXIT |
   +------+---+-----+-----+---+-----------+---+-----+---+---+------+

When LIT is invoked, since it's defined in code, IP will be pointing to the number 5. LIT simply
has to read it out of the thread, push it, and update IP to point to the proper next word. This
lets us write modular primitives for use by the compiler (it's very hard for a user to do this
directly within Forth). We will use the same trick to implement the control flow primitives
JUMP and 0BRANCH (and maybe N0BRANCH?).
*/

        defcode "LIT",3,,LIT
        pushd   TOS
        movd    TOS, [IP++]
        NEXT

        ; swap TOS and (DSP)
        defcode "SWAP",4,,SWAP
        popd    %rd0
        pushd   TOS
        movd    TOS, %rd0
        NEXT

        ; push a copy of TOS without changing TOS
        defcode "DUP",3,,DUP
        pushd   TOS
        NEXT

        ; ( x y -- x y x )
        defcode "OVER",4,,OVER
        pushd   TOS
        movd    TOS, [DSP+4]
        NEXT

        ; The next two can be optimized slightly with MMAI,
        ; but one of the target machines does not support it.

        ; ( x y z -- y z x )
        defcode "ROT",3,,ROT
        popd    %rd0            ; r0 = y
        popd    %rd1            ; r1 = x
        pushd   %rd0            ; push y on stack
        pushd   TOS             ; push z on stack
        movsd   TOS, %rd1       ; TOS is x
        NEXT

        ; ( x y z -- z x y )
        defcode "-ROT",4,,NROT
        popd    %rd0            ; r0 = y
        popd    %rd1            ; r1 = x
        pushd   TOS             ; push z on stack
        pushd   %rd1            ; push x on the stack
        movsd   TOS, %rd0       ; TOS is y
        NEXT

        ; ( x y -- y x y )
        defcode "TUCK",4,,TUCK
        popd    %rd0
        pushd   TOS
        pushd   %rd0
        NEXT

        ; ( x1 x2 -- )
        defcode "2DROP",5,,TWODROP
        addd    DSP, 4
        popd    TOS
        NEXT

        ; ( x1 x2 -- x1 x2 x1 x2 )
        defcode "2DUP",4,,TWODUP
        movd    %rd0, [DSP]     ; mov pseudo correctly picks ld for this
        pushd   TOS
        pushd   %rd0
        NEXT

        ; ( x1 x2 y1 y2 -- y1 y2 x1 x2 )
        defcode "2SWAP",5,,TWOSWAP
        popd    %rd0            ; r0 = y1
        popd    %rd1            ; r1 = x2
        popd    %rd2            ; r2 = x1
        pushd   %rd0
        pushd   TOS
        pushd   %rd2
        movsd   TOS, %rd1
        NEXT

        ; ( x -- 0 | x x)
        defcode "?DUP",4,,QDUP
        testd   TOS, -1
        jz      2f              ; we could jnz DUP to save one word of space
                                ; but empirically, ?DUP is usually used in loops and so most
                                ; often the not-zero path is taken. Not-taken branches are
                                ; significantly faster on one of the target machines.
        pushd   TOS
2:      NEXT

        defcode "1+",2,,INC
        addd    TOS, 1
        NEXT

        defcode "1-",2,,DEC
        subd    TOS, 1
        NEXT

        defcode "CELL+",5,,CELLPLUS
        addd    TOS, 4
        NEXT

        defcode "CELLS",5,,CELLS
        shld    TOS, 2
        NEXT

        defcode "INVERT",6,,INVERT
        rsubd   TOS, -1
        NEXT

        .macro defbinop name, len, label, opcode
        defcode "\name", \len,, \label
        popd    %rd0
        \opcode TOS, %rd0
        NEXT
        .endm

        defbinop "+",1,PLUS,addd
        defbinop "-",1,MINUS,rsubd
        defbinop "AND",3,AND,andd
        defbinop "OR",2,OR,ord
        defbinop "XOR",3,XOR,xord

        ; LSHIFT and RSHIFT aren't symmetric so we do have to
        ; implement them separately with some shuffling around TOS.
        .macro defshift name, label, opcode
        defcode "\name",6,,\label
        movd    %rd0, TOS
        popd    TOS
        \opcode TOS, %rd0
        NEXT
        .endm

        defshift "LSHIFT",LSHIFT,shld
        defshift "RSHIFT",RSHIFT,shrd

        defcode "*",1,,TIMES
        popd    %rd0
        umulq   TOS, %rq0       ; This sequence is faster than umuld on one of the targets.
        movsd   TOS, TOS
        NEXT

        ; COMPARISONS
        ; All operations are ( x y -- f )
        ; "f" in stack diagrams means "flag" - a boolean value which is either all 1s or all 0s.
        ; If the name starts with U, then the comparison is unsigned, else signed.
        ; If the name starts with 0, the operator behaves as if 0 was pushed, and then the comparison
        ; was done. This is slightly confusing - the 0 appears on the left of the operator in the name,
        ; but is going to actually be the _right_ operand to the operator.
        ; <> is the historical name for !=.
 
        .macro defcmp name, len, label, cc
        defcode "\name",\len,,\label
        popd  %rd0
        cmpd  %rd0, TOS
        movd  TOS, 0
   c\cc movd  TOS, -1
        NEXT
        .endm

        defcmp "=",1,EQ,e
        defcmp "<>",2,NEQ,ne
        defcmp "<",1,LT,l
        defcmp ">",1,GT,g
        defcmp "<=",2,LEQ,le
        defcmp ">=",2,GEQ,ge
        defcmp "U<",2,ULT,b
        defcmp "U>",2,UGT,a
        defcmp "U<=",3,ULEQ,be
        defcmp "U>=",3,UGEQ,ae

        .macro def0cmp name, len, label, cc
        defcode "\name",\len,,\label
        cmpd  TOS, 0
        movd  TOS, 0
   c\cc movd  TOS, -1
        NEXT
        .endm

        def0cmp "0=",2,ZEQ,e
        def0cmp "0<>",3,ZNEQ,ne
        def0cmp "0<",2,ZLT,l
        def0cmp "0>",2,ZGT,g
        def0cmp "0<=",3,ZLEQ,le
        def0cmp "0>=",3,ZGEQ,ge

        ;; MATHEMATICAL PRIMITIVES STILL NEEDED/WANTED
        ;   "u" in stack diagrams means unsigned, "n" means signed integer.
        ;   /MOD is allowed to do either floored or symmetric division, provided
        ;   that the choice is documented. We choose symmetric, because it's what ETCa does.
        ; U/MOD ( u1 u2 -- u3 u4 ) divide u1 by u2, returning the quotient u4 and rem u3.
        ; /MOD  ( n1 n2 -- n3 n4 ) same as U/MOD, but signed.

        ; Optional double-precision arithmetic (not sure if we need it?)
        ; When "d" is the identifier in a stack diagram, it represents a double-cell value.
        ; Double cell values appear on the stack with the more significant cell on top.
        ; UM*    ( u1 u2 -- d ) unsigned multiply u1*u2, returning double-cell value d.
        ; UM/MOD ( ud u1 -- u2 u3 ) Divide ud by u1, giving quotient u3 and remainder u2.
        ; M*     ( n1 n2 -- d ) signed multiply n1*n2, returning double cell value d.
        ; FM/MOD ( d  n1 -- n2 n3 ) Signed divide d1 by n1, giving the FLOORED quotient n3...
        ; SM/REM ( d  n1 -- n2 n3 ) Divide d1 by n1, giving the SYMMETRIC quotient n3 and rem n2.
        ; S>D    ( n -- d ) Sign-extend a value to double precision.

/* RSTACK Operations

Forth supports several manipulations of its return stack. Recall that we have the return stack
pointed to by RSP (a pinned register). The standard operations >R, R>, and R@ allowing moving
values between the data and return stacks. The rule is that anything put on the return stack by
>R must be removed (either by R> or RDROP) before the word that did it can return, because the
data is blocking the return address. But for the same reason, we can't implement these words as
forth words that have ENTER as their entry code, because then *their* return address would block
how we want to move the data! Instead, these are primitive words.

Perhaps add 2>R and 2R>?

The additional words RP@ RP! SP@ and SP! in some Forths allow direct manipulation of the data
and return stack pointers. This is useful for implementing `THROW` and `CATCH`. Since this is
only a bootstrapping Forth, we're not too concerned about those, and we can add them later if
needed.

*/

        defcode ">R",2,,TO_R
        PUSHRSP TOS
        popd    TOS
        NEXT

        defcode "R>",2,,FROM_R
        pushd   TOS
        POPRSP  TOS
        NEXT

        defcode "R@",2,,R_FETCH
        pushd   TOS
        movsd   TOS, [RSP]
        NEXT

        defcode "RDROP",5,,RDROP
        addd    RSP, 4
        NEXT

/* Memory Operations */

        ; ( a-addr -- x )
        defcode "@",1,,FETCH
        movsd   TOS, [TOS]
        NEXT

        ; ( x a-addr -- )
        defcode "!",1,,STORE        
        popd    %rd0
        movsd   [TOS], %rd0
        popd    TOS
        NEXT

        ; ( x a-addr -- )
        ; [a-addr]+=x
        defcode "+!",2,,PLUS_STORE
        popd    %rd0
        addd    [TOS], %rd0
        popd    TOS
        NEXT

        ; ( x a-addr -- )
        ; [a-addr]-=x
        defcode "-!",2,,MINUS_STORE
        popd    %rd0
        subd    [TOS], %rd0
        popd    TOS
        NEXT

        ; Those are all dword-oriented operations. Byte operations are also useful:
        
        defcode "C@",2,,FETCH_BYTE
        movzh   TOS, [TOS]
        NEXT

        defcode "C!",2,,STORE_BYTE
        popd    %rd0
        movh    [TOS], %rh0
        popd    TOS
        NEXT

        ; As is aligning pointers

        ; ( addr -- a-addr )
        ; return the first aligned address at least addr
        defcode "ALIGNED",7,,ALIGNED
        addd    TOS, 3
        andd    TOS, -4
        NEXT

        ; Align the HERE pointer.
        defword "ALIGN",5,,ALIGN
        .int    HERE, FETCH, ALIGNED, HERE, STORE
        .int    EXIT

/* Forth Variables (and Built-in Variables)

A Forth variable (declared by `VARIABLE <NAME>`) is a Forth word that pushes a dedicated data
address on the stack. This address can then be used with @ and ! to manipulate the value of the
variable. Forth has a few built-in variables, namely STATE, HERE, and BASE.

STATE records whether we are interpreting or compiling. This bootstrapping Forth only needs to
support minimal interpretation, but all interpretation is equally minimal, so we just have to
support it. HERE records the current value of the bump allocation pointer. The address that will
next be allocated by `,` is the current value of HERE. BASE records the current base used for
inputting and outputting numbers. This bootstrap Forth only supports base 10, so we don't need it.

We additionally support a variable LATEST, which points to the last dictionary entry created by
`BUILD` (which is called by `CREATE` and `:` etc.). So, it will be unset before the first word
is created in whatever Forth script is being run.

Similarly we could make constants, but we don't need any for our purposes.

*/

        .macro defvar name, len
        defcode "\name",\len,,\name
        pushd   TOS
        movd    TOS, var_\name
        NEXT

        .bss
        .p2align 2
var_\name :
        .space 4
        .endm

        defvar "STATE",5
        defvar "HERE",4
        defvar "LATEST",6

        ; internal NT-FIND operation which takes (on the stack) a pointer to a string and its
        ; length and searches for a dictionary entry with that name.
        ; The name is copied into the word buffer, which is also used by PARSE and PARSE-NAME, so
        ; there's a bit of synchronization that has to be handled with care. When ?FIND is passed
        ; a string parsed by PARSE or PARSE-NAME, it needs to copy the string into the same place
        ; non-destructively! The solution: PARSE and PARSE-NAME put the string in the buffer
        ; starting at index 1, not index 0. This leaves one byte of space to copy the length, and
        ; the rest of the copy will proceed as normal (4 bytes/iter if aligned, 1b/iter otherwise).
        ; Returns: 0 if not found, otherwise nt (in TOS).
        ; ( c-addr u -- nt | 0 )
        defcode "NT-FIND",7,,NT_FIND
        popd    %rd0                    ; c-addr -> r0
        movd    %rd1, WORD_BUFFER
        call    copy_name               ; name -> WORD_BUFFER
        ; r0 - r3 are free for use
        movd    %rd0, WORD_BUFFER       ; &WORD_BUFFER -> r0
        movd    TOS, [var_LATEST]       ; latest entry -> TOS
2:      movd    %rd1, 4                 ; offset_of(ENTRY, cstr)
        addd    %rd1, TOS               ; latest entry name -> r1
        call    cmp_name                ; clobber r2, names =? -> FLGS (Z => =)
        je      3f                      ; Yes, exit
        movd    TOS, [TOS]              ; (entry.link) -> TOS
        testd   TOS, -1                 ; is ptr null?
        jnz     2b                      ; No, loop
3:      NEXT                            ; Otherwise exit.

        ; inputs: %rh3 length, %rd0 pointer to source string, %rd1 destination
        ; outputs: nothing
        ; clobbers %r0-r3
        ; no stack effects
        .p2align 2 ; prevent fetch stalls
copy_name:
        ; copy length to buffer
        movh    [%rd1], %rh3
        ; copy 3 characters to buffer (might overrun string, that's OK)
        movh    %rh2, [%rd0++]
        movh    [%rd1+1], %rh2
        movh    %rh2, [%rd0++]
        movh    [%rd1+2], %rh2
        movh    %rh2, [%rd0++]
        movh    [%rd1+3], %rh2
        addd    %rd1, 4
        subh    %rh3, 3                 ; len -= 3
        retz                            ; if the len is now 0, short circuit exit.
        ; otherwise if len went negative, skip to 0 insertion for 4-byte copy
        jn      3f                      ; local 3: 4-byte copy insert 0s at end

        testd   %rd0, 3                 ; is the string pointer now aligned?
        jnz     5f                      ; local 5: 1-byte copy loop top

2:      movd    %rd2, [%rd0++]
        movd    [%rd1], %rd2            ; copy 4 bytes to buffer
        addd    %rd1, 4
        subh    %rh3, 4
        ja      2b                      ; %rd1 += 4, then loop if < stop pointer
        ; if we wrote too many bytes, now we have to insert some zeroes
3:      movh    %rh0, 0                 ; we will want to write 0s
        lead    %rd2, [4*%rd3 + 4f]     ; %rd2 = 4f - overshoot*4
        jmp     %rd2                    ; jump to appropriate instruction

        ; here to 4 is a table of instructions for inserting the right number of 0s
        ; each group must be 4 bytes of code!
        ; Aligning them prevents a fetch stall as well.
        .p2align 2
        ; insert 3
        movh    [%rd1 + -3], %rh0       ; *(p-3) = 0
        ; insert 2
        movh    [%rd1 + -2], %rh0       ; *(p-2) = 0
        ; insert 
        movh    [%rd1 + -1], %rh0       ; *(p-1) = 0
        ; insert none, i.e. we're done.
4:      ret

        ; now a byte copy loop. We get here if the input %rd0 was not 1 mod 4.
        ; guaranteed that %rh3 (len) is positive.
5:      movh    %rh2, [%rd0++]
        movh    [%rd1], %rh2            ; copy one byte
        addd    %rd1, 1                 ; (char*)%rd1++
        subh    %rh3, 1                 ; len--
        ja      5b                      ; loop if len > 0
        ; write 0s until %rd1 is 4-byte aligned
        movh    %rh0, 0                 ; done with string ptr, but will write 0s
        jmp     7f                      ; enter loop at test
6:      movh    [%rd1], %rh0            ; *p = 0
        addd    %rd1, 1                 ; p++
7:      testd   %rd1, 3                 ; 4-byte aligned?
        jnz     6b                      ; loop if not
        ret                             ; else done.

        ; inputs: %rd0 word buffer, %rd1 name to compare (both counted strings)
        ; clobbers: %r1, %r2
        ; returns: %rd0 still word buffer, zero flag set if names are equal
cmp_name:
        movd    %rd2, %rd0
        ; special case first word: bit 7 of length byte is F_IMMED, so clear that.
        movd    %rd9, [%rd1++]
        andd    %rd9, 0xFFFFFF7F
        cmpd    %rd9, [%rd2]            ; compare first words
        retne                           ; not equal: return with zero flag clear
        andh    %rh9, F_LENMASK         ; name length -> r9
        shrh    %rh9, 2                 ; name length in words -> r9
        addh    %rh9, 1                 ; add one for the word we already compared
        jmp     2f                      ; enter loop at test
3:      movd    %rd10, [%rd1++]         ; next word from p -> r10
        cmpd    %rd10, [%rd2]           ; compared to next word from buf
        retne                           ; not equal: return with zero flag clear
2:      addd    %rd2, 4                 ; buf++
        subh    %rh9, 1                 ; dec len
        jg      3b                      ; was more than 1? yes: loop
        ret                             ; len went to 0, so zero flag is set. Return.

        .bss
        .p2align 2
WORD_BUFFER:
        .space 40

/* Parsing Input

Forth defines two words for parsing input: `PARSE` and `PARSE-NAME`. There's also a third word,
`WORD`, but we won't implement it because it's obsolete and `PARSE-NAME` does its job better.

`PARSE` takes a character on the stack and then reads input characters until seeing that one.
We could make it also stop when it reads \NUL, but this is unnecessary because such conditions
only arise from malformed code (the last word in the file will be parsed by PARSE-NAME, not PARSE).
The delimiter character is consumed but not in the resulting string. The resulting string is
returned as a `c-addr u` stack pair. The `c-addr` will always be to `WORD_BUFFER+1`, but this
is a detail specific to this implementation.

`PARSE-NAME` behaves like `PARSE`, except it also skips whitespace before starting to parse
and is delimited by _any_ whitespace instead of by ' ' specifically. "Whitespace" is considered
a character value <= ' '. Notably this includes 0, so no special check is needed.

The key question becomes: how do we actually read the next character of input? And here is the crux
of a difficult question for a bootstrapping system - how powerful should it be? For portability,
and even usability as a BIOS, the system should really (*really*) support multiple modes of input,
ideally including an interactive one, and some way to specify which mode is actually to be used.
This is certainly possible, but it's quite a challenge!

However, it's also OK if we go small. This is a bootstrapping Forth, and is not intended to act
as a BIOS. So we can forgo interactivity entirely. For now, we'll assume the existence of a single
MMIO address which we can read to get the next character of an input file. If that file wants to
define some way to take interactive input and then give control to an interactive interpreter,
it can do that. By doing it this way, we lower the burden on our Forth. And the system is more
likely to be used to bootstrap a LISP or BASIC implementation, I believe, than an interactive
Forth (which is too low-level for e.g. implementing a higher-level language interactively).
If bootstrapping an interactive LISP, the Forth code that implements the LISP will have been
required to define new parsing words anyway! So all our interactivity effort would have been
wasted.

To reiterate: we assume the existence of a singular MMIO address that can read one input character
at a time. Imagine the MMIO is connected to a file. However it could also feasibly trigger an
interrupt, which then busywaits for a keyboard input, or something like that.

*/

        ; ( char "ccc<char>" -- c-addr u )
        defcode "PARSE",5,,PARSE
        movd    %rd0, WORD_BUFFER+1
        movd    %rd1, %rd0              ; save initial ptr
        jmp     2f                      ; enter loop at load
3:      movh    [%rd0], %rh2            ; write char to buffer
        addd    %rd0, 1                 ; bump buffer pointer
2:      loadh   %rh2, INPUT_STREAM      ; load char
        cmph    %rh2, TOS               ; is char the delimiter?
        jne     3b                      ; No.
        pushd   %rd1                    ; push c-addr
        subd    %rd0, %rd1              ; u = current - initial
        movd    TOS, %rd0               ; TOS = u
        NEXT

        ; ( "<spaces>ccc<space>" -- c-addr u )
        defcode "PARSE-NAME",10,,PARSE_NAME
        ; in the first loop to discard whitespace, we do have to check specially for \NUL,
        ; or else we will just end up spinning forever at end-of-file and never return the
        ; 0-length string we are supposed to read.
        mov     %rd0, WORD_BUFFER+1
        pushd   TOS                     ; push TOS, we are pushing two things here
        pushd   %rd0                    ; push c-addr
        movd    TOS, 0                  ; zero u
        movh    %rh1, ' '               ; stash ' ' which we will cmp against several times
        jmp     2f                      ; enter loop at load
        .p2align 1                      ; FI for ' ' misaligned instructions.
        ; worth optimizing to only check for 0 if we already know it's whitespace,
        ; because whitespace is rare and 0 is rarer.
3:      cmph    %rh2, 0                 ; \NUL?
        je      4f                      ; Yes, go run NEXT.
        ; Read the next character.
        ; not worth putting ' ' in a register because more than
        ; one iteration is rare.
2:      loadh   %rh2, INPUT_STREAM      ; load char
        cmph    %rh2, %rh1              ; Whitespace?
        jbe     3b                      ; Yes.
        ; Now read characters into the buffer, stop on whitespace.
        movd    TOS, %rd0               ; save initial ptr where it can easily become u
                                        ; fallthrough into loop
3:      movh    [%rd0], %rh2            ; write char to buffer
        addd    %rd0, 1                 ; bump buffer pointer
2:      loadh   %rh2, INPUT_STREAM      ; load char
        cmph    %rh2, %rh1              ; Whitespace?
        ja      3b                      ; No.
        ; already pushed c-addr, so we just have to set u.
        rsubd   TOS, %rd0               ; u = current ptr - start ptr
4:      NEXT

        ; TODO: NUMBER ( cs-addr -- n u )
        ; (cs-addr is a counted string)
        ; Returns the string converted to a number, and the number of unconverted characters.
        ; If u is 0, then n is the numeric value of the string, otherwise n is undefined.
        ; Only base 10 is supported.
        ; If the input string has length 0, ( x 1 ) is returned on the stack.
        defcode "NUMBER",6,,NUMBER
        movh    %rh0, [TOS++]           ; *cs-addr++ -> len
        movd    %rd1, 0                 ; 0 -> n
        cmph    %rh0, 0                 ; is len 0?
        jnz     2f                      ; No, enter loop at top
        movh    %rh0, 1                 ; indicate failure
        jmp     3f                      ; and jump to return code
2:      movh    %rh2, [TOS++]           ; next-char -> r2
        subh    %rh2, '0'               ; next-char <? '0'
        jb      3f                      ; Yes, we're done.
        cmph    %rh2, 9                 ; next-char >? '9'
        ja      3f                      ; Yes, also done.
        umulq   %rq1, 10                ; n *= 10
        addd    %rd1, %rd2              ; n += digit
        subh    %rh0, 1                 ; len--
        jnz     2b                      ; Loop if len is still not 0
3:      pushd   %rd1                    ; push n
        movzh   TOS, %rh0               ; u -> TOS (0 if fallthrough, nonzero if loop exit)
        NEXT

/* Define in Forth or in Assembly?

With that, we've implemented most of the code that really must be
written in assembly.

Writing code in Forth is easier than writing it in assembly, but slower.
For our purposes, "easy" is extremely valuable. So we'll often prefer that
even when there's a (small enough) runtime or space cost.

That said, I have a pretty high tolerance for what I consider "easy" in
assembly. Some words here _could_ be defined in Forth, but I define them
in assembly anyway. This choice should be made by the author of the
bootstrap Forth and there is of course no obligation to make the same
choices as me. Words executed often should get some preference towards
being implemented in assembly in either case.

*/

        ; Continuing with functions used to manipulate the dictionary...
        ; * `,` is used in compilation (or any time) to append to the newest entry.
        ; * `COMPILE` executes the compilation semantics of the name token on the stack.
        ;       It is placed here for proximity to `,`.
        ; * `HIDDEN` toggles the F_SMUDGE bit on the NT given in TOS.
        ; * `IMMEDIATE` sets the F_IMMED bit on the latest entry. It's itself F_IMMED
        ;       to allow an older Forth style of writing it in the definition instead of after.
        ; * `BUILD` forms a new dictionary entry given a name (without setting the code field).
        ; * `:` uses BUILD to make a new dictionary entry, sets F_SMUDGE, switches
        ;       to compile mode, and writes `jmp ENTER_PIN` into the code field.
        ; * `;` writes EXIT into the current entry, unsmudges it, then switches to interpret mode.
        ; * The pair of words CREATE and DOES> are significantly more complicated and unlikely
        ;       to be required for bootstrapping with Forth. The actual implementation would
        ;       not be that bad, but the _concept_ is complex. So we'll leave it off for now.
        ;       (actually, they might be very useful for implementing a language. hmm.)

        ; ( x -- )
        ; Write x to HERE and bump it.
        defcode ",",1,,COMMA
        call    _COMMA
        popd    TOS                     ; remove x from the stack
        NEXT

        ; append value in TOS to current definition. Clobbers %r0.
_COMMA: loadd   %rd0, var_HERE          ; movd r,[d] syntax mistakenly selects movsd
_COMMAH: ; use this one if (HERE) is already in rd0
        movd    [%rd0], TOS
        addd    %rd0, 4                 ; bump value of HERE
        stored  %rd0, var_HERE          ; and save it back
        ret

        ; ( nt -- )
        ; Compile nt for the current def. If nt is an entry for an immediate
        ; word, execute that word. Otherwise, append NT>XT(nt) to the current
        ; definition as with `,`.
        ; This is placed here for proximity to `,` so that the common jump can
        ; be short. Placing `EXECUTE` nearby would make them both short, but
        ; we'll favor code organization just a bit there.
        defcode "COMPILE",7,,COMPILE
        addd    TOS, 4                  ; name field
        movh    %rh0, [TOS]             ; len+flags -> r0
        movh    %rh1, %rh0              ; len+flags -> r1
        ; partial inline of NT_TO_XT
        andh    %rh1, F_LENMASK&-4      ; len -> r1
        lead    TOS, [TOS + 1*%rd1 + 4] ; xt  -> TOS
        cmph    %rh0, 0                 ; flags negative? (F_IMMED is 0x80, using test
        jnn     COMMA                   ;   would be slower on one of the targets.)
        ljmp    EXECUTE                 ; tail-call correct behavior.

        ; ( nt -- )
        defcode "HIDDEN",6,,HIDDEN
        xorh    [TOS+4], F_SMUDGE       ; toggle F_SMUDGE bit of given nt
        popd    TOS                     ; and drop the nt
        NEXT

        ; ( -- )
        defcode "IMMEDIATE",9,F_IMMED,IMMEDIATE
        loadd   %rd0, var_LATEST        ; (LATEST) -> r0
        orh     [%rd0+4], F_IMMED       ; set F_IMMED bit on latest entry
        NEXT

        ; ( c-addr u -- nt )
        defcode "BUILD",5,,BUILD
        popd    %rd2                    ; c-addr -> r2 stash away briefly
        loadd   %rd0, var_HERE          ; (HERE) -> r0
        addd    %rd0, 3                 ; align up
        andd    %rd0, -4                ;   to 4 bytes
        pushd   %rd0                    ; that's the nt we will return.
        pushd   TOS                     ; stash u on the stack for a while
        loadd   TOS, var_LATEST         ; (LATEST) -> TOS
        call    _COMMAH                 ; write link field
        subd    %rd0, 4                 ; pointer to link field
        stored  %rd0, var_LATEST        ; write that to (LATEST)
        movd    TOS, [DSP]              ; retrieve u to arg:"len" but leave it saved on stack
        loadd   %rd1, var_HERE          ; (HERE) -> arg:"dst"
        movd    %rd0, %rd2              ; c-addr -> arg:"src"
        call    copy_name               ; copy the name into the dictionary
        popd    TOS                     ; restore length
        andd    TOS, -4                 ; (len / 4)*4 (num bytes with padding, less 4)
        addd    TOS, 4                  ; now num bytes with padding
        addd    [var_HERE], TOS         ; increment (HERE) by that much.
        popd    TOS                     ; drop length (pulls down nt)
        NEXT

        ; ( "<spaces>name<space>" -- )
        defword ":",1,,COLON
        .int    PARSE_NAME, BUILD       ; read a name and make an entry
        .int    HIDDEN                  ; smudge it
        .int    LIT
        jmp     ENTER_PIN               ; LIT will read the encoding of this
        .p2align 2                      ; plus zero to align it again
        .int    COMMA                   ; write that instruction into the code field
        .int    RBRAC, EXIT             ; Enter compilation state and exit

        defword ";",1,F_IMMED,SEMICOLON
        .int    LIT, EXIT, COMMA        ; compile EXIT to current definition
        .int    LATEST, FETCH, HIDDEN   ; Un-smudge that definition
        .int    LBRAC, EXIT             ; switch to interpret state and exit

        ; Switch to interpretation state from compile state. Note F_IMMED.
        defcode "[",1,F_IMMED,LBRAC
        movd    [var_STATE], 0
        NEXT

        ; Switch to compilation state.
        defcode "]",1,,RBRAC
        movd    [var_STATE], 1
        NEXT

        ; ( nt -- xt )
        defcode ">XT",3,,NT_TO_XT
        addd    TOS, 4                  ; name field
        movh    %rh0, [TOS]             ; len+flags -> r0
        andd    %rd0, F_LENMASK&-4      ; len -> r0
        lead    TOS, [TOS + 1*%rd0 + 4] ; %rd0+4 is word-aligned length, add into TOS
        NEXT

/* Control Flow

Just like LIT, control flow operations have a parameter: the target.
It turns out that all we need to implement all of Forth's control flow primitives
is an unconditional BRANCH and a conditional branch-on-0 named 0BRANCH. The parameter
to both will be a 32-bit signed offset, relative to the address of the offset itself.

  +--------+---------+--- - - ---+--------+--------+--- - - ---+----------+
  | HEADER | jmp %r8 |           | BRANCH | offset | (skipped) | words... |
  +--------+---------+--- - - ---+--------+-|------+--- - - ---+----------+
                                            |                    ^
                                            |                    |
                                            +---- IP+offset -----+

*/

        defcode "BRANCH",6,,BRANCH
        add     IP, [IP]                ; read and add offset into IP
        NEXT

        defcode "0BRANCH",7,,ZBRANCH
        cmpd    TOS, 0                  ; top of stack is zero?
        popd    TOS                     ; remove top of stack
        jz      BRANCH                  ; Yes zero, use BRANCH above.
        addd    IP, 4                   ; skip offset.
        NEXT

        ; ( xt -- )
        ; invoke the given xt
        defcode "EXECUTE",7,,EXECUTE
        movd    %rd0, TOS               ; copy xt to %rd0 (calling convention)
        popd    TOS                     ; drop xt from stack
        jmp     %rd0                    ; xt's NEXT will continue - we never return here.

        ; Crash the program, signaling failure in a basic way.
HALT:   movh    %rh15, -1
        hlt

        ; main interpreter loop
        ; while (1):
        ;   cname = PARSE_NAME
        ;   nt = NT_FIND(cname)
        ;   if nt:
        ;     xt = NT>XT(nt)
        ;     if STATE:
        ;       COMMA(xt)
        ;     else:
        ;       EXECUTE(xt)
        ;   else:
        ;     (n,u) = NUMBER(WORD_BUFFER)
        ;     if u:
        ;       hlt
        ;     if STATE:  
        ;       COMMA(LIT)
        ;       COMMA(n)
        ;     else:
        ;       LIT(n)
        defword "QUIT",4,,QUIT
QUITL:  .int PARSE_NAME, NT_FIND        ; parse and lookup name
        .int QDUP, ZBRANCH, 3f-.        ; didn't find name, branch to number check
        .int STATE, FETCH               ; check STATE
        .int ZBRANCH, 2f-.              ; interpret state, jump fwd
        .int COMPILE, BRANCH, QUITL-.   ; Compile: we have a word for this. Then loop.
2:      .int NT_TO_XT, EXECUTE          ; Interpret: execute xt, 
        .int BRANCH, QUITL-.            ;   then loop.
3:      .int LIT, WORD_BUFFER, NUMBER   ; try to parse word as a base-10 number
        .int ZBRANCH, 4f-.              ; Succeeded, go to process lit
        .int DROP, HALT                 ; not a word or number, crash
4:      .int STATE, FETCH               ; check STATE
        .int ZBRANCH, QUITL-.           ; interpret state, n is TOS already, so loop
        .int LIT, LIT, COMMA            ; Compile LIT into current def
        .int COMMA, BRANCH, QUITL-.     ; compile num into current def, then loop

        ; this has to stay at the bottom of the file. It gives the initial value for LATEST
        ; based on the last created dictionary entry (recall that local label 1 is used
        ; exclusively for tracking the last dicionary entry).
        .set init_LATEST, 1b-4
