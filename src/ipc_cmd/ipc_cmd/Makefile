OBJECTS_C = ipc_cmd.o ptz.o
OBJECTS_R = ipc_read.o
OBJECTS_N = ipc_notify.o
OBJECTS_2 = ipc2file.o motion_metadata_events.o
#LIBS = -lpthread -lrt

all: ipc_cmd ipc_read ipc_notify ipc2file ipc_multiplex.so record_metadata.so nightvision.so nightvisionctl record_preroll-y623.bin record_preroll-y28ga.bin

PREROLL_FLAGS = -marm -march=armv7-a -Os -Wall -Wextra -Werror -ffreestanding -fno-builtin -fno-pic -fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables

record_preroll-y623.o: record_preroll.c
	$(CC) $(PREROLL_FLAGS) -DPREROLL_Y623 -c $< -o $@

record_preroll-y28ga.o: record_preroll.c
	$(CC) $(PREROLL_FLAGS) -DPREROLL_Y28GA -c $< -o $@

record_preroll-y623-asm.o: record_preroll.S
	$(CC) $(PREROLL_FLAGS) -DPREROLL_Y623 -c $< -o $@

record_preroll-y28ga-asm.o: record_preroll.S
	$(CC) $(PREROLL_FLAGS) -DPREROLL_Y28GA -c $< -o $@

record_preroll-y623.elf: record_preroll-y623.o record_preroll-y623-asm.o record_preroll.ld
	$(LD) -T record_preroll.ld --defsym PREROLL_BASE=0x19000 record_preroll-y623.o record_preroll-y623-asm.o -o $@

record_preroll-y28ga.elf: record_preroll-y28ga.o record_preroll-y28ga-asm.o record_preroll.ld
	$(LD) -T record_preroll.ld --defsym PREROLL_BASE=0x18000 record_preroll-y28ga.o record_preroll-y28ga-asm.o -o $@

record_preroll-%.bin: record_preroll-%.elf
	$(OBJCOPY) -O binary -j .text $< $@

%.o: %.c $(HEADERS)
	$(CC) -c $< -fPIC -Os -o $@

ipc_multiplex.so: ipc_multiplex.c dispatch_poll.c ipc_multiplex.h
	$(CC) ipc_multiplex.c dispatch_poll.c -fPIC -Os -shared -pthread -ldl -lrt -o $@

record_metadata.so: record_metadata.c motion_metadata_events.c motion_metadata_events.h
	$(CC) record_metadata.c motion_metadata_events.c -std=c11 -Wall -Wextra -fPIC -Os -shared -pthread -ldl -lrt -o $@

nightvision.so: nightvision.c nightvision.h
	$(CC) nightvision.c -std=c11 -Wall -Wextra -fPIC -Os -shared -o $@

nightvisionctl: nightvisionctl.c nightvision.h
	$(CC) nightvisionctl.c -std=c11 -Wall -Wextra -Os -o $@
	$(STRIP) $@

ipc2file.o motion_metadata_events.o: motion_metadata_events.h

ipc_cmd: $(OBJECTS_C)
	$(CC) $(OBJECTS_C) $(LIBS) -fPIC -Os -o $@
	$(STRIP) $@

ipc_read: $(OBJECTS_R)
	$(CC) $(OBJECTS_R) $(LIBS) -fPIC -Os -o $@
	$(STRIP) $@

ipc_notify: $(OBJECTS_N)
	$(CC) $(OBJECTS_N) $(LIBS) -fPIC -Os -o $@
	$(STRIP) $@

ipc2file: $(OBJECTS_2)
	$(CC) $(OBJECTS_2) $(LIBS) -fPIC -Os -o $@
	$(STRIP) $@

.PHONY: clean

clean:
	rm -f record_preroll-*.o record_preroll-*.elf record_preroll-*.bin
	rm -f ipc_cmd
	rm -f ipc_read
	rm -f ipc_notify
	rm -f ipc2file
	rm -f ipc_multiplex.so
	rm -f record_metadata.so
	rm -f nightvision.so nightvisionctl
	rm -f $(OBJECTS_C)
	rm -f $(OBJECTS_R)
	rm -f $(OBJECTS_N)
	rm -f $(OBJECTS_2)
