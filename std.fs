: \ 10 PARSE 2DROP ; IMMEDIATE
\ This file is a "standard library" for ETCa Forth. It doesn't install
\ an interactive interpreter, so it's really intended to be used as a
\ starting point for writing whatever program you actually want.
: ( 41 PARSE 2DROP ; IMMEDIATE \ 41 = )
\ Note that \ and () comments are limited to 128 characters long.
\ take a value off the stack and compile code to push that value.
: LITERAL ['] LIT , , ; IMMEDIATE
: NEGATE 0 SWAP - ;
\ compile the following word even if it would normally be immediate.
: [COMPILE] PARSE-NAME NT-FIND >XT , ; IMMEDIATE
\ ['] doesn't work for immediate words. Use this if you need it to.
\ : ['] PARSE-NAME NT-FIND >XT [COMPILE] LITERAL ; IMMEDIATE

\ Control Structures
\ We need IF ... THEN and loops to do stuff. But we can define them in Forth!
\ Such control words only work in compilation mode. They work by leaving addresses
\ of "relocations" to fixup later on the stack (or possibly inside other relocations!).
\ condition IF true-part THEN rest
\   --compiles--> condition 0BRANCH OFFSET true-part rest
\   where OFFSET is the offset from itself to 'rest'
\ condition IF true-part ELSE false-part THEN
\   --compiles--> condition 0BRANCH OFFSET true-part BRANCH OFFSET false-part rest

\ IF compiles 0BRANCH and a dummy offset, and saves the reloc address on the stack.
: IF ['] 0BRANCH , HERE @ 0 , ; IMMEDIATE
\ RESOLVE resolves a relocation by setting it to the offset to HERE.
: RESOLVE ( reloc -- ) HERE @ OVER - SWAP ! ;
\ THEN just resolves the reloc on the stack.
: THEN RESOLVE ; IMMEDIATE
\ ELSE compiles a new branch and dummy offset, then resolves the existing one.
: ELSE ['] BRANCH , HERE @ 0 , SWAP RESOLVE ; IMMEDIATE

\ BEGIN loop-body condition UNTIL
\   --compiles--> loop-body condition 0BRANCH OFFSET
: BEGIN HERE @ ; IMMEDIATE
: UNTIL ['] 0BRANCH , HERE @ - , ; IMMEDIATE

\ BEGIN loop-body AGAIN
\   --compiles--> loop-body BRANCH OFFSET
\ makes an infinite loop
: AGAIN ['] BRANCH , HERE @ - , ; IMMEDIATE

\ BEGIN condition WHILE loop-body REPEAT
\   --compiles--> condition 0BRANCH OFFSET2 loop-body BRANCH OFFSET
\ like while (condition) { loop-body }
: WHILE ['] 0BRANCH , HERE @ 0 , ; IMMEDIATE
: REPEAT ['] BRANCH , SWAP HERE @ - , RESOLVE ; IMMEDIATE

\ UNLESS is IF but the condition is reversed.
: UNLESS ['] 0= , [COMPILE] IF ; IMMEDIATE

\ PICK and ROLL should be implemented in forth.S if at all.
\ c a b WITHIN is true iff a <= c and c < b
: WITHIN OVER - >R - R> U< ;

\ Allocate dictionary space and return a pointer to it. Space is in bytes.
\ Use <num> CELLS ALLOT to allocate space in cells.
: ALLOT HERE @ SWAP HERE +! ;

\ C, is , but for bytes.
: C, HERE C! 1 HERE +! ;

\ Tiny fragment of an assembler to help write VARIABLE and CONSTANT.
\ intent is to call BUILD instead of ':' to avoid writing 'jmp %rd8' to the codeword.
\ Then you can write ETCa code into the word directly. ENDCODE will write NEXT to the thread.
\ encode NEXT: 2C 10 AF 0E. `HERE` must be aligned!
: ENDCODE 246353964 , ;

\ Assembler word: write ETCa machine code to push the word on the stack. That is:
\ pushd TOS; movd TOS, <value>.
\ THIS RELIES ON `HERE` CURRENTLY BEING ALIGNED!
\ The prefix is 2D CC 29 6D.
: PUSH, 1831455789 , , ;

\ VARIABLE allocates a cell, then creates a new entry which just
\ pushes the address of that cell.
: VARIABLE 4 ALLOT PARSE-NAME BUILD DROP PUSH, ENDCODE ;
: CONSTANT PARSE-NAME BUILD DROP PUSH, ENDCODE ;

32 CONSTANT BL \ space
10 CONSTANT NL \ newline
\ Boolean words
-1 CONSTANT TRUE
0 CONSTANT FALSE
: NOT   0= ;

2147483648 CONSTANT CONSOLE
VARIABLE CON-ROW 0 CON-ROW !
VARIABLE CON-COL 0 CON-COL !

\ Print an ASCII character to the console. TODO: screen clear. 0xA is newline.
: EMIT ( char -- )
  DUP NL = IF \ newline, set col to 80
    80 CON-COL !
  ELSE
    CON-ROW @ 80 * CON-COL @ + CONSOLE + C! \ compute offset and write
    1 CON-COL +! \ increment column
  THEN
  CON-COL @ 80 >= IF \ col now exceeds 79
    0 CON-COL !
    1 CON-ROW +!
  THEN
;

\ Print a newline
: CR NL EMIT ;

: C@++ ( c-addr -- c-addr+1 c )
  DUP 1+ SWAP C@
;

: TYPE ( c-addr u -- )
  BEGIN DUP WHILE
    SWAP C@++ EMIT SWAP
    1-
  REPEAT
  2DROP
;

\ LITSTRING is like LIT, but for strings. It could be implemented in forth.S, but it's instructive
\ to see how to do it in Forth. We will lay out strings as their length followed by the string
\ content (padded to a multiple of 4 bytes, of course). This representation is called a
\ "counted string." LITSTRING reads its own return address to find the address of the counted
\ string, pushes the appropriate values, modifies its own return address, and then returns.
: LITSTRING ( -- c-addr u )
  R> C@++
  2DUP + 3 + -4 AND
  >R
;

\ S" ...string..." parses the string (everything up to the closing ") and compiles code to push
\ the string and its length. To do that, we have to copy the string from PARSE, so we abuse the
\ knowledge that parse always returns a 1mod4-aligned pointer with the character before free.
: S" ['] LITSTRING , 34 PARSE ( c-addr u )
  SWAP 1- ( u c-addr-1 )
  2DUP C!
  SWAP ( c-addr-1 u )
  BEGIN
    >R 
    DUP @ , CELL+
    R> 4 - DUP 0<
  UNTIL
  2DROP
; IMMEDIATE

\ Compile code to print the ("-terminated) string after this word.
: ." [COMPILE] S" ['] TYPE , ; IMMEDIATE

: TABLE CREATE ALLOT DOES> + ;
3 TABLE ARRAY
48 0 ARRAY C!
49 1 ARRAY C!
50 2 ARRAY C!

0 ARRAY C@ EMIT
1 ARRAY C@ EMIT
2 ARRAY C@ EMIT
