OBJECTS = motiond.o motion_metadata_levels.o
LIBS += -lrt

all: motiond

motiond.o: motiond.c motion_tuning.h motion_delivery.h motion_mask.h ../../ipc_cmd/ipc_cmd/motion_map.h ../../ipc_cmd/ipc_cmd/motion_metadata_levels.h
	$(CC) -c $< -fPIC -Os -o $@

motion_metadata_levels.o: ../../ipc_cmd/ipc_cmd/motion_metadata_levels.c ../../ipc_cmd/ipc_cmd/motion_metadata_levels.h
	$(CC) -std=c11 -c $< -fPIC -Os -o $@

motiond: $(OBJECTS)
	$(CC) $(OBJECTS) $(LIBS) -fPIC -Os -o $@
	$(STRIP) $@

.PHONY: clean

clean:
	rm -f motiond
	rm -f $(OBJECTS)
