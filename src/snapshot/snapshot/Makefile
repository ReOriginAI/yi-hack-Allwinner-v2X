.SHELLFLAGS := -eu -c
FFMPEG_VERSION = 8.1.1
OBJECTS = imggrabber.o convert2jpg.o add_water.o water_mark.o
FFMPEG = ffmpeg-$(FFMPEG_VERSION)
FFMPEG_DIR = ./$(FFMPEG)
INC_FF = -I$(FFMPEG_DIR)
LIB_FF = $(FFMPEG_DIR)/libavcodec/libavcodec.a $(FFMPEG_DIR)/libavutil/libavutil.a -lpthread -lm
GRID_FFMPEG_DIR = ./$(FFMPEG)-grid
LIB_GRID_FF = $(GRID_FFMPEG_DIR)/libavcodec/libavcodec.a $(GRID_FFMPEG_DIR)/libavutil/libavutil.a -lm
JPEGLIB_VERSION = 3.1.4.1
JPEGLIB = libjpeg-turbo-$(JPEGLIB_VERSION)
JPEGLIB_DIR = ./$(JPEGLIB)
INSTALL_LIB_J = $(JPEGLIB_DIR)/_install
INC_J = -I$(INSTALL_LIB_J)/include
LIB_J = $(INSTALL_LIB_J)/lib/libjpeg.a
OPTS = -Os -ffunction-sections -fdata-sections

all:
	$(MAKE) libs
	$(MAKE) imggrabber
	$(MAKE) grid

# The flash profile needs only the low H.264 reference image for the motion grid.
# Build separately so the full SD snapshot program retains all its capabilities.
grid:
	$(MAKE) grid-libs
	$(MAKE) imggrabber-grid

grid-libs:
	@$(build_grid_ffmpeg)

imggrabber-grid.o: imggrabber.c $(HEADERS)
	$(CC) -c $< $(OPTS) -DYI_SNAPSHOT_GRID $(INC_J) -I$(GRID_FFMPEG_DIR) -fPIC -o $@

imggrabber-grid: imggrabber-grid.o convert2jpg.o
	$(CC) -Os -Wl,--gc-sections $^ $(LIB_J) $(LIB_GRID_FF) -fPIC -o $@
	$(STRIP) $@

libs: 
	@$(build_ffmpeg)
	@$(build_jpeglib_turbo)

imggrabber.o: imggrabber.c $(HEADERS)
	$(CC) -c $< $(OPTS) $(INC_J) $(INC_FF) -fPIC -o $@

convert2jpg.o: convert2jpg.c $(HEADERS)
	$(CC) -c $< $(OPTS) $(INC_J) -fPIC -o $@

add_water.o: add_water.c $(HEADERS)
	$(CC) -c $< $(OPTS) $(INC_J) -fPIC -o $@

water_mark.o: water_mark.c $(HEADERS)
	$(CC) -c $< $(OPTS) $(INC_J) -fPIC -o $@

imggrabber: $(OBJECTS)
	$(CC) -Os -Wl,--gc-sections $(OBJECTS) $(LIB_J) $(LIB_FF) -fPIC -o $@
	$(STRIP) $@

.PHONY: all libs grid grid-libs clean distclean

clean:
	rm -f imggrabber
	rm -f imggrabber-grid
	rm -f imggrabber-grid.o
	rm -f $(OBJECTS)
	rm -rf $(FFMPEG)
	rm -rf $(GRID_FFMPEG_DIR)
	rm -rf $(JPEGLIB)

distclean: clean
	rm -rf SDK
	rm -rf $(JPEGLIB)

define build_ffmpeg
    python3 ../../../scripts/fetch_snapshot_source.py ffmpeg $(FFMPEG_VERSION) SDK/ffmpeg.tar

    # Both verified source archives contain the same release under different roots.
    if [ ! -f $(FFMPEG_DIR)/README.md ]; then \
        mkdir -p $(FFMPEG_DIR); \
        tar xf SDK/ffmpeg.tar --strip-components=1 -C $(FFMPEG_DIR); \
    fi
    printf '%s\n' '$(FFMPEG_VERSION)' > $(FFMPEG_DIR)/VERSION

    # build
    if [ ! -f $(FFMPEG_DIR)/libavcodec/libavcodec.a ] || [ ! -f $(FFMPEG_DIR)/libavutil/libavutil.a ]; then \
         cd $(FFMPEG_DIR); \
        ./configure --enable-cross-compile --cross-prefix=$(CROSSPREFIX) --arch=armhf --target-os=linux --prefix=$(CROSSPATH) --enable-thumb --enable-small --disable-ffplay --disable-ffprobe --disable-doc  --disable-decoders --enable-decoder=h264 --enable-decoder=hevc --disable-encoders --disable-demuxers --enable-demuxer=h264 --enable-demuxer=hevc --disable-muxers --disable-protocols --disable-parsers --enable-parser=h264 --enable-parser=hevc --disable-filters --disable-bsfs --disable-indevs --disable-outdevs --extra-cflags="-Os -ffunction-sections -fdata-sections"; \
         $(MAKE); \
         cd ..;\
    fi
endef

define build_grid_ffmpeg
    python3 ../../../scripts/fetch_snapshot_source.py ffmpeg $(FFMPEG_VERSION) SDK/ffmpeg.tar
    if [ ! -f $(GRID_FFMPEG_DIR)/configure ]; then \
        mkdir -p $(GRID_FFMPEG_DIR); \
        tar xf SDK/ffmpeg.tar --strip-components=1 -C $(GRID_FFMPEG_DIR); \
    fi
    printf '%s\n' '$(FFMPEG_VERSION)' > $(GRID_FFMPEG_DIR)/VERSION
    if [ ! -f $(GRID_FFMPEG_DIR)/libavcodec/libavcodec.a ] || [ ! -f $(GRID_FFMPEG_DIR)/libavutil/libavutil.a ]; then \
        cd $(GRID_FFMPEG_DIR); \
        ./configure --enable-cross-compile --cross-prefix=$(CROSSPREFIX) --arch=armhf --target-os=linux \
            --enable-thumb --enable-small --disable-everything --disable-autodetect \
            --disable-programs --disable-doc --disable-network --disable-pthreads \
            --disable-avformat --disable-avdevice --disable-avfilter \
            --disable-swresample --disable-swscale --enable-decoder=h264 \
            --extra-cflags="-Os -ffunction-sections -fdata-sections"; \
        $(MAKE); \
    fi
endef

define build_jpeglib_turbo
    python3 ../../../scripts/fetch_snapshot_source.py jpeg $(JPEGLIB_VERSION) SDK/jpeg.tar.gz

    if [ ! -f $(JPEGLIB)/README.md ]; then \
        mkdir -p $(JPEGLIB); \
        tar xf SDK/jpeg.tar.gz --strip-components=1 -C $(JPEGLIB); \
    fi

    # build
    if [ ! -f $(LIB_J) ]; then \
        cd ./$(JPEGLIB); \
        patch -p1 < ../../fix_HWCAP_ARM.patch; \
        cmake -DCMAKE_TOOLCHAIN_FILE="../arm-openwrt-linux-toolchain.cmake" -DCMAKE_INSTALL_PREFIX="../$(INSTALL_LIB_J)" -DWITH_JPEG7=1 -DWITH_JPEG8=1 -DNEON_INTRINSICS=1 -DWITH_SIMD=1; \
        $(MAKE); \
        $(MAKE) install; \
        cd ..;\
    fi
endef
        # $(MAKE) CFLAGS+="-m32 -Os -ffunction-sections -fdata-sections "; \
