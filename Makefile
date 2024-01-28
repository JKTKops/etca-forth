
EXTENSIONS = INT,PM,MO1,MO2,FI,SAF,BYTE,DW,QW,DWAS,REX,ASP,EXOP
ARCH_ARG = -march=base+$(EXTENSIONS)
MODEL = -mcmodel=medany -mpw=d

AS = etca-elf-as $(ARCH_ARG) $(MODEL)
CPP = gcc -x assembler-with-cpp -E -P

forth:	forth.o
	etca-elf-ld -T linker_script.lds forth.o -o forth
	etca-elf-objcopy -O binary forth forth.bin
	cp forth.bin /mnt/c/Users/zergl/AppData/Roaming/godot/app_userdata/Turing\ Complete/schematics/architecture/ETCA/uETCa-v1/
	rm forth

forth.o:	forth.s
	$(CPP) forth.s | $(AS) -o forth.o

#	$(AS) forth.s -o forth.o

annotated:	forth.pre
	etca-as.py $(ARCH_ARG) $(MODEL) forth.pre -o forth.ann

forth.pre:	forth.s
	$(CPP) forth.s > forth.pre

clean:
	rm forth forth.ann forth.bin forth.o forth.pre
