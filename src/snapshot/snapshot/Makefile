OBJECTS = imggrabber.o convert2jpg.o add_water.o water_mark.o
FFMPEG = ffmpeg-8.1.1
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
    # get archive
    if [ ! -f SDK/ffmpeg.tar.bz2 ]; then \
        mkdir -p SDK; \
        wget -O ./SDK/ffmpeg.tar.bz2.tmp "https://ffmpeg.org/releases/$(FFMPEG).tar.bz2"; \
        mv ./SDK/ffmpeg.tar.bz2.tmp ./SDK/ffmpeg.tar.bz2; \
    fi

    # untar
    if [ ! -f $(FFMPEG_DIR)/README.md ]; then \
         tar jxvf ./SDK/ffmpeg.tar.bz2; \
    fi

    # build
    if [ ! -f $(FFMPEG_DIR)/libavcodec/libavcodec.a ] || [ ! -f $(FFMPEG_DIR)/libavutil/libavutil.a ]; then \
         cd $(FFMPEG_DIR); \
        ./configure --enable-cross-compile --cross-prefix=$(CROSSPREFIX) --arch=armhf --target-os=linux --prefix=$(CROSSPATH) --enable-thumb --enable-small --disable-ffplay --disable-ffprobe --disable-doc  --disable-decoders --enable-decoder=h264 --enable-decoder=hevc --disable-encoders --disable-demuxers --enable-demuxer=h264 --enable-demuxer=hevc --disable-muxers --disable-protocols --disable-parsers --enable-parser=h264 --enable-parser=hevc --disable-filters --disable-bsfs --disable-indevs --disable-outdevs --extra-cflags="-Os -ffunction-sections -fdata-sections" && \
         $(MAKE); \
         cd ..;\
    fi
endef

define build_grid_ffmpeg
    if [ ! -f $(GRID_FFMPEG_DIR)/configure ]; then \
        mkdir -p $(GRID_FFMPEG_DIR); \
        tar jxf SDK/ffmpeg.tar.bz2 --strip-components=1 -C $(GRID_FFMPEG_DIR); \
    fi
    if [ ! -f $(GRID_FFMPEG_DIR)/libavcodec/libavcodec.a ] || [ ! -f $(GRID_FFMPEG_DIR)/libavutil/libavutil.a ]; then \
        cd $(GRID_FFMPEG_DIR); \
        ./configure --enable-cross-compile --cross-prefix=$(CROSSPREFIX) --arch=armhf --target-os=linux \
            --enable-thumb --enable-small --disable-everything --disable-autodetect \
            --disable-programs --disable-doc --disable-network --disable-pthreads \
            --disable-avformat --disable-avdevice --disable-avfilter \
            --disable-swresample --disable-swscale --enable-decoder=h264 \
            --extra-cflags="-Os -ffunction-sections -fdata-sections" && \
        $(MAKE); \
    fi
endef

define build_jpeglib_turbo
    # get archive
    if [ ! -f SDK/jpeg.tar.gz ]; then \
        mkdir -p SDK; \
        wget -O ./SDK/jpeg.tar.gz.tmp "https://github.com/libjpeg-turbo/libjpeg-turbo/archive/refs/tags/$(JPEGLIB_VERSION).tar.gz"; \
        mv ./SDK/jpeg.tar.gz.tmp ./SDK/jpeg.tar.gz; \
    fi

    # untar
    if [ ! -f $(JPEGLIB)/README ]; then \
         tar zxvf ./SDK/jpeg.tar.gz; \
    fi

    # build
    if [ ! -f $(LIB_J) ]; then \
        cd ./$(JPEGLIB); \
        patch -p1 < ../../fix_HWCAP_ARM.patch; \
        cmake -DCMAKE_TOOLCHAIN_FILE="../arm-openwrt-linux-toolchain.cmake" -DCMAKE_INSTALL_PREFIX="../$(INSTALL_LIB_J)" -DWITH_JPEG7=1 -DWITH_JPEG8=1 -DNEON_INTRINSICS=1 -DWITH_SIMD=1; \
        make -j$(nproc); \
        make install; \
        cd ..;\
    fi
endef
        # $(MAKE) CFLAGS+="-m32 -Os -ffunction-sections -fdata-sections "; \
