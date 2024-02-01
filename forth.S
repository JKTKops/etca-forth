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
        mov     [--RSP], \src
        .endm
        .macro POPRSP dst
        mov     \dst, [RSP++]
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

#define TOS %rd3
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
        .p2align 3
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
.set DATA_STACK_BOTTOM,   0x800
; linker script is set to start RAM at 0x800.

        .text
        .p2align 3
main:                           ; TODO ext/ft check
        mov     %rx0, 2
        mov     %address_mode, %rx0     ; switch to real32

        mov     DSP, DATA_STACK_BOTTOM
        mov     RSP, RETURN_STACK_BOTTOM
        mov     ENTER_PIN, ENTER
        mov     IP, cold_start
        NEXT

        .section .rodata
cold_start:
        .int 0  ; TODO: should be .int QUIT

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
        defcode \name, \namelen, \flags, \label
        call ENTER_PIN
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
        test    TOS, -1
        jz      2f              ; we could jnz DUP to save one word of space
                                ; but empirically, ?DUP is usually used in loops and so most
                                ; often the not-zero path is taken. Not-taken branches are
                                ; significantly faster on one of the target machines.
        pushd   TOS
2:      NEXT

        ;; PRIMITIVES STILL NEEDED/WANTED

        ; 1+    ( x -- x+1 )
        ; 1-    ( x -- x-1 )

        ; these are optional but easy and I think used frequently
        ; CELL+ ( x -- x+4 )
        ; CELLS ( x -- x<<2 )

        ; back to (essentially) required
        ; +     ( x y -- x+y )
        ; -     ( x y -- x-y )
        ; *     ( x y -- x*y ) ignores upper word
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

        ; At least =, <, and U< are required, the rest are technical optional, but...
        ; a macro would probably make defining these very easy anyway.
        ; All operations are ( x y -- f )
        ; "f" in stack diagrams means "flag" - a boolean value which is either all 1s or all 0s.
        ; If the name starts with U, then the comparison is unsigned, else signed.
        ; If the name starts with 0, the operator behaves as if 0 was pushed, and then the comparison
        ; was done. This is slightly confusing - the 0 appears on the left of the operator in the name,
        ; but is going to actually be the _right_ operand to the operator.
        ; <> is the historical name for !=.
        ;
        ; = <> < > <= >=
        ; 0= 0<> 0< 0> 0<= 0>=
        ; U< U<= U> U>=

        ; other binary operations ( x y -- xOpY )
        ; AND OR XOR
        ; INVERT ( x -- ~x )
