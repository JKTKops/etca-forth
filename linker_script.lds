OUTPUT_FORMAT("elf32-etca", "elf32-etca", "elf32-etca")
OUTPUT_ARCH(etca)
ENTRY(_start)
SEARCH_DIR("/usr/local/etca-elf/lib");

MEMORY {
  rom (rx)   : ORIGIN = 0xFFFF8000, LENGTH = 32K
  ram (w!rx) : ORIGIN = 0x00000800, LENGTH = 2M
}

SECTIONS
{
  .text : {
    *(.text.startup .text.startup.*)
    *(SORT(.text.sorted.*))
    *(.text .text.*)
  }
  PROVIDE (__etext = .);
  .rotata : { *(.rodata .rodata.*) }

  .bss : {
    __bss_start = .;
    *(.bss .bss.*)
    *(COMMON)
  }
}
