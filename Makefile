
EXTENSIONS = INT,PM,MO1,MO2,FI,SAF,BYTE,DW,QW,DWAS,REX,ASP,EXOP
ARCH_ARG = -march=base+$(EXTENSIONS)
MODEL = -mcmodel=medany -mpw=d

AS = etca-elf-as $(ARCH_ARG) $(MODEL)
# The assembler that should be used to produce annotated output. I have a bash script in /usr/local/bin
# which calls out to the binutils-wrapper python script etca-as.py (it doesn't have an official
# installer, so this is the best I've got atm). If you've installed it differently, adjust this command.
ANN_AS = etca-as $(ARCH_ARG) $(MODEL)
CPP = gcc -x assembler-with-cpp -E -P

forth:	forth.o
	etca-elf-ld -T linker_script.lds forth.o -o forth
	etca-elf-objcopy -O binary forth forth.bin
	cp forth.bin /mnt/c/Users/zergl/AppData/Roaming/godot/app_userdata/Turing\ Complete/schematics/architecture/ETCA/uETCa-v1/

# rm forth

forth.o:	forth.S
	$(CPP) forth.S | $(AS) -o forth.o

annotated:	forth.pre
	$(ANN_AS) forth.pre -o forth.ann

forth.pre:	forth.S
	$(CPP) forth.S > forth.pre

clean:
	rm forth forth.ann forth.bin forth.o forth.pre
