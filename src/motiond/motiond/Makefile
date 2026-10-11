OBJECTS = motiond.o
LIBS += -lrt

all: motiond

motiond.o: motiond.c motion_tuning.h
	$(CC) -c $< -fPIC -Os -o $@

motiond: $(OBJECTS)
	$(CC) $(OBJECTS) $(LIBS) -fPIC -Os -o $@
	$(STRIP) $@

.PHONY: clean

clean:
	rm -f motiond
	rm -f $(OBJECTS)
