# Lower-half operation classification

Retention decisions apply only to the two exact firmware images inventoried here. Shell conditionals and comments are included with their surrounding operation; optional/unselected driver alternatives are not claimed necessary. No original lower-half script is sourced by the replacement.

## y623: /backup/lower_half_init.sh

Absent on this camera.

## y623: /home/app/lower_half_init.sh

SHA256: `cf6c3e5a972c24d4f8e61d44c15e861f4ec7f8b49b89322abeabdf8405210265`.

| Line | Operation | Classification / disposition |
|---:|---|---|
| 2 | `sdio_wifi_ssv6158='ssv6158'` | obsolete/unneeded (stock control flow or logging) |
| 3 | `sdio_wifi_8189fs='8189fs'` | obsolete/unneeded (stock control flow or logging) |
| 4 | `sdio_wifi_hi3881='hi3881'` | obsolete/unneeded (stock control flow or logging) |
| 6 | `mount -t vfat /dev/mmcblk0 /tmp/sd` | optional local feature: SD mount moved to guarded bootstrap |
| 7 | `if [ "${SUFFIX}" = "y211ga" ] &#124;&#124; [ "${SUFFIX}" = "y211ba" ];then` | obsolete/unneeded (stock control flow or logging) |
| 8 | `echo "need reset gpio198"` | obsolete/unneeded (stock control flow or logging) |
| 9 | `echo 198 > /sys/class/gpio/export` | required hardware/kernel initialization; only observed modules retained |
| 10 | `echo out > /sys/class/gpio/gpio198/direction` | required hardware/kernel initialization; only observed modules retained |
| 11 | `echo 0 > /sys/class/gpio/gpio198/value` | required hardware/kernel initialization; only observed modules retained |
| 12 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 13 | `echo 1 > /sys/class/gpio/gpio198/value` | required hardware/kernel initialization; only observed modules retained |
| 14 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 17 | `if [ "${enable_4g}" = "y" ];then` | obsolete/unneeded (stock control flow or logging) |
| 18 | `echo "4g is running...."` | obsolete/unneeded (stock control flow or logging) |
| 19 | `else` | obsolete/unneeded (stock control flow or logging) |
| 20 | `if [ -f /home/base/wifi/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 21 | `insmod /home/base/wifi/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 22 | `elif [ -f /home/base/wifi/8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 23 | `insmod /home/base/wifi/8189fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 24 | `elif [ -f /backup/ko/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 25 | `insmod /backup/ko/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 26 | `elif [ -f /backup/ko/8192fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 27 | `insmod /backup/ko/8192fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 28 | `elif [ -f /backup/ko/atbm603x_wifi_usb.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 29 | `insmod /backup/ko/atbm603x_wifi_usb.ko` | required hardware/kernel initialization; only observed modules retained |
| 30 | `elif [ -f /backup/ko/rdawfmac.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 31 | `insmod /backup/ko/rdawfmac.ko` | required hardware/kernel initialization; only observed modules retained |
| 32 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 34 | `if [ -f /backup/ko/ssv6x5x.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 35 | `if [ "${SUFFIX}" = "d071qp"  ];then` | obsolete/unneeded (stock control flow or logging) |
| 36 | `if [ -f /home/base/firmware/ssv6x5x/ssv6152-wifi.cfg ];then` | obsolete/unneeded (stock control flow or logging) |
| 37 | `insmod /backup/ko/ssv6x5x.ko stacfgpath="/home/base/firmware/ssv6x5x/ssv6152-wifi.cfg" wifi_type=SDIO` | required hardware/kernel initialization; only observed modules retained |
| 38 | `else` | obsolete/unneeded (stock control flow or logging) |
| 39 | `echo "not found ssv6x5x-wifi.cfg"` | obsolete/unneeded (stock control flow or logging) |
| 40 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 41 | `else` | obsolete/unneeded (stock control flow or logging) |
| 42 | `if [ -f /home/base/firmware/ssv6x5x/ssv6x5x-wifi.cfg ];then` | obsolete/unneeded (stock control flow or logging) |
| 43 | `insmod /backup/ko/ssv6x5x.ko stacfgpath="/home/base/firmware/ssv6x5x/ssv6x5x-wifi.cfg" wifi_type=$SSV_WIFI_TYPE` | required hardware/kernel initialization; only observed modules retained |
| 44 | `else` | obsolete/unneeded (stock control flow or logging) |
| 45 | `echo "not found ssv6x5x-wifi.cfg"` | obsolete/unneeded (stock control flow or logging) |
| 46 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 47 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 48 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 49 | `if [ -f /backup/ko/$sdio_wifi_ssv6158.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 50 | `if [ -f /home/base/firmware/ssv6158/ssv6158-wifi.cfg ];then` | obsolete/unneeded (stock control flow or logging) |
| 51 | `echo "insmod /backup/ko/$sdio_wifi_ssv6158.ko,SDIO mode"` | required hardware/kernel initialization; only observed modules retained |
| 52 | `insmod /backup/ko/$sdio_wifi_ssv6158.ko stacfgpath="/home/base/firmware/ssv6158/ssv6158-wifi.cfg" wifi_type=SDIO` | required hardware/kernel initialization; only observed modules retained |
| 53 | `echo "insmod /backup/ko/$sdio_wifi_ssv6158.ko,end"` | required hardware/kernel initialization; only observed modules retained |
| 54 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 55 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 56 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 58 | `if [ -f /backup/ko/$sdio_wifi_8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 59 | `echo "insmod /backup/ko/$sdio_wifi_8189fs.ko"` | required hardware/kernel initialization; only observed modules retained |
| 60 | `insmod /backup/ko/$sdio_wifi_8189fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 61 | `echo "insmod /backup/ko/$sdio_wifi_8189fs.ko end"` | required hardware/kernel initialization; only observed modules retained |
| 62 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 63 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 64 | `if [ -f /backup/ko/$sdio_wifi_hi3881.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 65 | `echo "insmod /backup/ko/$sdio_wifi_hi3881.ko"` | required hardware/kernel initialization; only observed modules retained |
| 66 | `insmod /backup/ko/$sdio_wifi_hi3881.ko` | required hardware/kernel initialization; only observed modules retained |
| 67 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 68 | `echo 'wlan0 set_sta_pm_on 0' > /sys/hisys/hipriv` | required network initialization; unused alternatives omitted |
| 69 | `echo 'wlan0 alg_cfg tpc_mode  0' > /sys/hisys/hipriv` | required network initialization; unused alternatives omitted |
| 70 | `echo 'wlan0 intrf_mode 0 1 1 1' > /sys/hisys/hipriv` | required network initialization; unused alternatives omitted |
| 71 | `echo "insmod /backup/ko/$sdio_wifi_hi3881.ko end"` | required hardware/kernel initialization; only observed modules retained |
| 72 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 73 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 75 | `echo "--------------------------insmod sensor--------------------------"` | required hardware/kernel initialization; only observed modules retained |
| 76 | `insmod /home/base/ko/videobuf2-core.ko` | required hardware/kernel initialization; only observed modules retained |
| 77 | `insmod /home/base/ko/videobuf2-memops.ko` | required hardware/kernel initialization; only observed modules retained |
| 78 | `insmod /home/base/ko/videobuf2-dma-contig.ko` | required hardware/kernel initialization; only observed modules retained |
| 79 | `insmod /home/base/ko/videobuf2-v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 80 | `insmod /home/base/ko/vin_io.ko` | required hardware/kernel initialization; only observed modules retained |
| 83 | `if [ "${SUFFIX}" = "b091qp" ];then` | obsolete/unneeded (stock control flow or logging) |
| 84 | `insmod /backup/ko/cam_sensor.ko` | required hardware/kernel initialization; only observed modules retained |
| 85 | `insmod /home/base/ko/vin_v4l2.ko ccm0=$SENSOR_DRIVE_NAME i2c0_addr=$SENSOR_ADDR` | required hardware/kernel initialization; only observed modules retained |
| 86 | `else` | obsolete/unneeded (stock control flow or logging) |
| 87 | `insmod /home/base/ko/cam_sensor.ko` | required hardware/kernel initialization; only observed modules retained |
| 88 | `insmod /home/base/ko/vin_v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 89 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 92 | `if [ -f /home/base/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 93 | `insmod /home/base/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 94 | `elif [ -f /backup/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 95 | `insmod /backup/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 96 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 98 | `if [ -f /home/base/ko/sunxi_gpadc.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 99 | `insmod /home/base/ko/sunxi_gpadc.ko` | required hardware/kernel initialization; only observed modules retained |
| 100 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 107 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 108 | `ifconfig lo up` | required network initialization; unused alternatives omitted |
| 110 | `ifconfig ${NETWORK_IFACE} up` | required network initialization; unused alternatives omitted |
| 116 | `ethmac=d2:`ifconfig ${NETWORK_IFACE} &#124;grep HWaddr&#124;cut -d' ' -f10&#124;cut -d: -f2-`` | required network initialization; unused alternatives omitted |
| 125 | `ifconfig eth0 hw ether $ethmac` | required network initialization; unused alternatives omitted |
| 126 | `a=1` | obsolete/unneeded (stock control flow or logging) |
| 127 | `if [ "${SUFFIX}" = "b111qp" ] &#124;&#124; [ "${SUFFIX}" = "b101qp" ] &#124;&#124; [ "${SUFFIX}" = "b092qp" ] &#124;&#124; [ "${SUFFIX}" = "b091qp" ] &#124;&#124; [ "${SUFFIX}" = "q321br_aldz_3m" ]; then` | obsolete/unneeded (stock control flow or logging) |
| 128 | `while ( ! ifconfig eth0 up)` | required network initialization; unused alternatives omitted |
| 129 | `do` | obsolete/unneeded (stock control flow or logging) |
| 130 | `echo "ifconfig eth0 up failed"` | required network initialization; unused alternatives omitted |
| 131 | `let a++` | obsolete/unneeded (stock control flow or logging) |
| 132 | `if [ $a -eq 10 ]; then` | obsolete/unneeded (stock control flow or logging) |
| 133 | `break` | obsolete/unneeded (stock control flow or logging) |
| 134 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 135 | `done` | obsolete/unneeded (stock control flow or logging) |
| 136 | `else` | obsolete/unneeded (stock control flow or logging) |
| 137 | `ifconfig eth0 up` | required network initialization; unused alternatives omitted |
| 138 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 140 | `ln -s /home/model/BodyVehicleAnimal3.model /tmp/BodyVehicleAnimal3.model` | obsolete/unneeded: disabled AI pipeline model link |
| 141 | `echo "============================================= home low_half_init.sh... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 142 | `echo "============================================= begin to start app... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 143 | `cd /home/app` | required rmm/media initialization |
| 144 | `if [ -f /home/app/property ];then` | obsolete/unneeded launch hook for local operation; omitted |
| 145 | `./property &` | obsolete/unneeded launch hook for local operation; omitted |
| 146 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 149 | `if [ -f "/tmp/sd/Factory/factory_test.sh" ]; then` | obsolete/unneeded launch hook for local operation; omitted |
| 150 | `/tmp/sd/Factory/config.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 151 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 152 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 154 | `if [ -f "/tmp/sd/factory_aging_test.sh" ]; then` | obsolete/unneeded launch hook for local operation; omitted |
| 156 | `./dispatch &` | required local IPC initialization; bootstrap owns startup |
| 157 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 158 | `./rmm &` | required rmm/media initialization; system.sh owns startup |
| 159 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 160 | `./mp4record &` | optional local feature: recording |
| 161 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 162 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 164 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 165 | `export DEVICE_MEMORY=8000000` | required rmm/media initialization |
| 166 | `export CPU_MEMORY=-1` | required rmm/media initialization |
| 167 | `export LD_LIBRARY_PATH=/tmp/:$LD_LIBRARY_PATH` | required rmm/media initialization |
| 168 | `export PATH=/home/app:/home/app/script:$PATH` | required rmm/media initialization |
| 170 | `if [ -f "/tmp/sd/log_tools.tar.gz" ];then` | Yi telemetry/diagnostic launch hook; omitted |
| 171 | `echo "run log_tools start."` | Yi telemetry/diagnostic launch hook; omitted |
| 172 | `if [ ! -d /tmp/sd/log_tools ];then` | Yi telemetry/diagnostic launch hook; omitted |
| 173 | `cd /tmp/sd` | obsolete/unneeded (stock control flow or logging) |
| 174 | `mkdir log_tools` | Yi telemetry/diagnostic launch hook; omitted |
| 175 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 176 | `cd /tmp/sd` | obsolete/unneeded (stock control flow or logging) |
| 177 | `tar -zxvf log_tools.tar.gz -C /tmp/sd/log_tools` | Yi telemetry/diagnostic launch hook; omitted |
| 178 | `chmod +x /tmp/sd/log_tools/run_log_app.sh` | Yi telemetry/diagnostic launch hook; omitted |
| 179 | `/tmp/sd/log_tools/run_log_app.sh` | Yi telemetry/diagnostic launch hook; omitted |
| 180 | `cd -` | obsolete/unneeded (stock control flow or logging) |
| 181 | `echo "run log_tools end."` | Yi telemetry/diagnostic launch hook; omitted |
| 183 | `else` | obsolete/unneeded (stock control flow or logging) |
| 184 | `./dispatch &` | required local IPC initialization; bootstrap owns startup |
| 185 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 186 | `./rmm &` | required rmm/media initialization; system.sh owns startup |
| 187 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 188 | `./mp4record &` | optional local feature: recording |
| 189 | `./cloud &` | Yi cloud; ablated |
| 190 | `./p2p_tnp &` | Yi P2P; ablated |
| 191 | `./oss &` | Yi upload/storage; ablated |
| 192 | `./rtmp &` | Yi upload/storage; ablated |
| 193 | `./watch_process &` | Yi cloud; ablated |
| 194 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 196 | `chmod 777 /tmp/sd/debug.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 197 | `sh /tmp/sd/debug.sh &` | obsolete/unneeded launch hook for local operation; omitted |
| 199 | `echo "rmmod not used wifi module"` | required network initialization; unused alternatives omitted |
| 208 | `wifi_module_state=$(cat /sys/class/misc/sunxi-wlan/rf-ctrl/sdio_wifi_name)` | required network initialization; unused alternatives omitted |
| 209 | `echo "wifi_module_state=$wifi_module_state"` | required network initialization; unused alternatives omitted |
| 210 | `if [ "$wifi_module_state" == "2" ]; then` | required network initialization; unused alternatives omitted |
| 211 | `echo "rmmod $sdio_wifi_ssv6158.ko"` | required network initialization; unused alternatives omitted |
| 212 | `rmmod $sdio_wifi_ssv6158` | required network initialization; unused alternatives omitted |
| 213 | `elif [ "$wifi_module_state" == "3" ]; then` | required network initialization; unused alternatives omitted |
| 214 | `echo "rmmod $sdio_wifi_ssv6158.ko"` | required network initialization; unused alternatives omitted |
| 215 | `rmmod $sdio_wifi_ssv6158` | required network initialization; unused alternatives omitted |
| 216 | `echo "rmmod $sdio_wifi_8189fs.ko"` | required network initialization; unused alternatives omitted |
| 217 | `rmmod $sdio_wifi_8189fs` | required network initialization; unused alternatives omitted |
| 218 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 220 | `echo "============================================= end home low_half_init.sh... ========================================="` | obsolete/unneeded (stock control flow or logging) |

## y623: /tmp/sd/lower_half_init.sh

SHA256: `224691f9df836783c4e61e7a689c041ea65b81f75b3ad56f88c2ddb8014f0b69`.

| Line | Operation | Classification / disposition |
|---:|---|---|
| 4 | `if [ -f /tmp/init_started ]; then` | obsolete/unneeded (stock control flow or logging) |
| 5 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 6 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 8 | `touch /tmp/init_started` | obsolete/unneeded (stock control flow or logging) |
| 9 | `sdio_wifi_ssv6158='ssv6158'` | obsolete/unneeded (stock control flow or logging) |
| 10 | `sdio_wifi_8189fs='8189fs'` | obsolete/unneeded (stock control flow or logging) |
| 11 | `sdio_wifi_hi3881='hi3881'` | obsolete/unneeded (stock control flow or logging) |
| 13 | `mount -t vfat /dev/mmcblk0 /tmp/sd` | optional local feature: SD mount moved to guarded bootstrap |
| 14 | `if [ "${SUFFIX}" = "y211ga" ] &#124;&#124; [ "${SUFFIX}" = "y211ba" ];then` | obsolete/unneeded (stock control flow or logging) |
| 15 | `echo "need reset gpio198"` | obsolete/unneeded (stock control flow or logging) |
| 16 | `echo 198 > /sys/class/gpio/export` | required hardware/kernel initialization; only observed modules retained |
| 17 | `echo out > /sys/class/gpio/gpio198/direction` | required hardware/kernel initialization; only observed modules retained |
| 18 | `echo 0 > /sys/class/gpio/gpio198/value` | required hardware/kernel initialization; only observed modules retained |
| 19 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 20 | `echo 1 > /sys/class/gpio/gpio198/value` | required hardware/kernel initialization; only observed modules retained |
| 21 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 24 | `if [ "${enable_4g}" = "y" ];then` | obsolete/unneeded (stock control flow or logging) |
| 25 | `echo "4g is running...."` | obsolete/unneeded (stock control flow or logging) |
| 26 | `else` | obsolete/unneeded (stock control flow or logging) |
| 27 | `if [ -f /home/base/wifi/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 28 | `insmod /home/base/wifi/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 29 | `elif [ -f /home/base/wifi/8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 30 | `insmod /home/base/wifi/8189fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 31 | `elif [ -f /backup/ko/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 32 | `insmod /backup/ko/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 33 | `elif [ -f /backup/ko/8192fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 34 | `insmod /backup/ko/8192fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 35 | `elif [ -f /backup/ko/atbm603x_wifi_usb.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 36 | `insmod /backup/ko/atbm603x_wifi_usb.ko` | required hardware/kernel initialization; only observed modules retained |
| 37 | `elif [ -f /backup/ko/rdawfmac.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 38 | `insmod /backup/ko/rdawfmac.ko` | required hardware/kernel initialization; only observed modules retained |
| 39 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 41 | `if [ -f /backup/ko/ssv6x5x.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 42 | `if [ "${SUFFIX}" = "d071qp"  ];then` | obsolete/unneeded (stock control flow or logging) |
| 43 | `if [ -f /home/base/firmware/ssv6x5x/ssv6152-wifi.cfg ];then` | obsolete/unneeded (stock control flow or logging) |
| 44 | `insmod /backup/ko/ssv6x5x.ko stacfgpath="/home/base/firmware/ssv6x5x/ssv6152-wifi.cfg" wifi_type=SDIO` | required hardware/kernel initialization; only observed modules retained |
| 45 | `else` | obsolete/unneeded (stock control flow or logging) |
| 46 | `echo "not found ssv6x5x-wifi.cfg"` | obsolete/unneeded (stock control flow or logging) |
| 47 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 48 | `else` | obsolete/unneeded (stock control flow or logging) |
| 49 | `if [ -f /home/base/firmware/ssv6x5x/ssv6x5x-wifi.cfg ];then` | obsolete/unneeded (stock control flow or logging) |
| 50 | `insmod /backup/ko/ssv6x5x.ko stacfgpath="/home/base/firmware/ssv6x5x/ssv6x5x-wifi.cfg" wifi_type=$SSV_WIFI_TYPE` | required hardware/kernel initialization; only observed modules retained |
| 51 | `else` | obsolete/unneeded (stock control flow or logging) |
| 52 | `echo "not found ssv6x5x-wifi.cfg"` | obsolete/unneeded (stock control flow or logging) |
| 53 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 54 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 55 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 56 | `if [ -f /backup/ko/$sdio_wifi_ssv6158.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 57 | `if [ -f /home/base/firmware/ssv6158/ssv6158-wifi.cfg ];then` | obsolete/unneeded (stock control flow or logging) |
| 58 | `echo "insmod /backup/ko/$sdio_wifi_ssv6158.ko,SDIO mode"` | required hardware/kernel initialization; only observed modules retained |
| 59 | `insmod /backup/ko/$sdio_wifi_ssv6158.ko stacfgpath="/home/base/firmware/ssv6158/ssv6158-wifi.cfg" wifi_type=SDIO` | required hardware/kernel initialization; only observed modules retained |
| 60 | `echo "insmod /backup/ko/$sdio_wifi_ssv6158.ko,end"` | required hardware/kernel initialization; only observed modules retained |
| 61 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 62 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 63 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 65 | `if [ -f /backup/ko/$sdio_wifi_8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 66 | `echo "insmod /backup/ko/$sdio_wifi_8189fs.ko"` | required hardware/kernel initialization; only observed modules retained |
| 67 | `insmod /backup/ko/$sdio_wifi_8189fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 68 | `echo "insmod /backup/ko/$sdio_wifi_8189fs.ko end"` | required hardware/kernel initialization; only observed modules retained |
| 69 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 70 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 71 | `if [ -f /backup/ko/$sdio_wifi_hi3881.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 72 | `echo "insmod /backup/ko/$sdio_wifi_hi3881.ko"` | required hardware/kernel initialization; only observed modules retained |
| 73 | `insmod /backup/ko/$sdio_wifi_hi3881.ko` | required hardware/kernel initialization; only observed modules retained |
| 74 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 75 | `echo 'wlan0 set_sta_pm_on 0' > /sys/hisys/hipriv` | required network initialization; unused alternatives omitted |
| 76 | `echo 'wlan0 alg_cfg tpc_mode  0' > /sys/hisys/hipriv` | required network initialization; unused alternatives omitted |
| 77 | `echo 'wlan0 intrf_mode 0 1 1 1' > /sys/hisys/hipriv` | required network initialization; unused alternatives omitted |
| 78 | `echo "insmod /backup/ko/$sdio_wifi_hi3881.ko end"` | required hardware/kernel initialization; only observed modules retained |
| 79 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 80 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 82 | `echo "--------------------------insmod sensor--------------------------"` | required hardware/kernel initialization; only observed modules retained |
| 83 | `insmod /home/base/ko/videobuf2-core.ko` | required hardware/kernel initialization; only observed modules retained |
| 84 | `insmod /home/base/ko/videobuf2-memops.ko` | required hardware/kernel initialization; only observed modules retained |
| 85 | `insmod /home/base/ko/videobuf2-dma-contig.ko` | required hardware/kernel initialization; only observed modules retained |
| 86 | `insmod /home/base/ko/videobuf2-v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 87 | `insmod /home/base/ko/vin_io.ko` | required hardware/kernel initialization; only observed modules retained |
| 90 | `if [ "${SUFFIX}" = "b091qp" ];then` | obsolete/unneeded (stock control flow or logging) |
| 91 | `insmod /backup/ko/cam_sensor.ko` | required hardware/kernel initialization; only observed modules retained |
| 92 | `insmod /home/base/ko/vin_v4l2.ko ccm0=$SENSOR_DRIVE_NAME i2c0_addr=$SENSOR_ADDR` | required hardware/kernel initialization; only observed modules retained |
| 93 | `else` | obsolete/unneeded (stock control flow or logging) |
| 94 | `insmod /home/base/ko/cam_sensor.ko` | required hardware/kernel initialization; only observed modules retained |
| 95 | `insmod /home/base/ko/vin_v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 96 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 99 | `if [ -f /home/base/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 100 | `insmod /home/base/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 101 | `elif [ -f /backup/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 102 | `insmod /backup/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 103 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 105 | `if [ -f /home/base/ko/sunxi_gpadc.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 106 | `insmod /home/base/ko/sunxi_gpadc.ko` | required hardware/kernel initialization; only observed modules retained |
| 107 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 114 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 115 | `ifconfig lo up` | required network initialization; unused alternatives omitted |
| 117 | `ifconfig ${NETWORK_IFACE} up` | required network initialization; unused alternatives omitted |
| 123 | `ethmac=d2:`ifconfig ${NETWORK_IFACE} &#124;grep HWaddr&#124;cut -d' ' -f10&#124;cut -d: -f2-`` | required network initialization; unused alternatives omitted |
| 132 | `ifconfig eth0 hw ether $ethmac` | required network initialization; unused alternatives omitted |
| 133 | `a=1` | obsolete/unneeded (stock control flow or logging) |
| 134 | `if [ "${SUFFIX}" = "b111qp" ] &#124;&#124; [ "${SUFFIX}" = "b101qp" ] &#124;&#124; [ "${SUFFIX}" = "b092qp" ] &#124;&#124; [ "${SUFFIX}" = "b091qp" ] &#124;&#124; [ "${SUFFIX}" = "q321br_aldz_3m" ]; then` | obsolete/unneeded (stock control flow or logging) |
| 135 | `while ( ! ifconfig eth0 up)` | required network initialization; unused alternatives omitted |
| 136 | `do` | obsolete/unneeded (stock control flow or logging) |
| 137 | `echo "ifconfig eth0 up failed"` | required network initialization; unused alternatives omitted |
| 138 | `let a++` | obsolete/unneeded (stock control flow or logging) |
| 139 | `if [ $a -eq 10 ]; then` | obsolete/unneeded (stock control flow or logging) |
| 140 | `break` | obsolete/unneeded (stock control flow or logging) |
| 141 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 142 | `done` | obsolete/unneeded (stock control flow or logging) |
| 143 | `else` | obsolete/unneeded (stock control flow or logging) |
| 144 | `ifconfig eth0 up` | required network initialization; unused alternatives omitted |
| 145 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 147 | `ln -s /home/model/BodyVehicleAnimal3.model /tmp/BodyVehicleAnimal3.model` | obsolete/unneeded: disabled AI pipeline model link |
| 148 | `echo "============================================= home low_half_init.sh... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 149 | `echo "============================================= begin to start app... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 150 | `cd /home/app` | required rmm/media initialization |
| 151 | `if [ -f /home/app/property ];then` | obsolete/unneeded launch hook for local operation; omitted |
| 152 | `./property &` | obsolete/unneeded launch hook for local operation; omitted |
| 153 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 156 | `if [ -f "/tmp/sd/Factory/factory_test.sh" ]; then` | obsolete/unneeded launch hook for local operation; omitted |
| 157 | `/tmp/sd/Factory/config.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 158 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 159 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 161 | `if [ -f "/tmp/sd/factory_aging_test.sh" ]; then` | obsolete/unneeded launch hook for local operation; omitted |
| 163 | `./dispatch &` | required local IPC initialization; bootstrap owns startup |
| 164 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 165 | `./rmm &` | required rmm/media initialization; system.sh owns startup |
| 166 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 167 | `./mp4record &` | optional local feature: recording |
| 168 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 169 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 171 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 172 | `export DEVICE_MEMORY=8000000` | required rmm/media initialization |
| 173 | `export CPU_MEMORY=-1` | required rmm/media initialization |
| 174 | `export LD_LIBRARY_PATH=/tmp/:$LD_LIBRARY_PATH` | required rmm/media initialization |
| 175 | `export PATH=/home/app:/home/app/script:$PATH` | required rmm/media initialization |
| 177 | `if [ -f "/tmp/sd/log_tools.tar.gz" ];then` | Yi telemetry/diagnostic launch hook; omitted |
| 178 | `echo "run log_tools start."` | Yi telemetry/diagnostic launch hook; omitted |
| 179 | `if [ ! -d /tmp/sd/log_tools ];then` | Yi telemetry/diagnostic launch hook; omitted |
| 180 | `cd /tmp/sd` | obsolete/unneeded (stock control flow or logging) |
| 181 | `mkdir log_tools` | Yi telemetry/diagnostic launch hook; omitted |
| 182 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 183 | `cd /tmp/sd` | obsolete/unneeded (stock control flow or logging) |
| 184 | `tar -zxvf log_tools.tar.gz -C /tmp/sd/log_tools` | Yi telemetry/diagnostic launch hook; omitted |
| 185 | `chmod +x /tmp/sd/log_tools/run_log_app.sh` | Yi telemetry/diagnostic launch hook; omitted |
| 186 | `/tmp/sd/log_tools/run_log_app.sh` | Yi telemetry/diagnostic launch hook; omitted |
| 187 | `cd -` | obsolete/unneeded (stock control flow or logging) |
| 188 | `echo "run log_tools end."` | Yi telemetry/diagnostic launch hook; omitted |
| 190 | `else` | obsolete/unneeded (stock control flow or logging) |
| 191 | `mount --bind /tmp/sd/yi-hack/script/wifidhcp.sh /home/app/script/wifidhcp.sh` | required network initialization; bind checked for failure |
| 192 | `mount --bind /tmp/sd/yi-hack/script/wifidhcp.sh /backup/tools/wifidhcp.sh` | required network initialization; bind checked for failure |
| 193 | `mount --bind /tmp/sd/yi-hack/script/ethdhcp.sh /home/app/script/ethdhcp.sh` | required network initialization; bind checked for failure |
| 194 | `mount --bind /tmp/sd/yi-hack/script/ethdhcp.sh /backup/tools/ethdhcp.sh` | required network initialization; bind checked for failure |
| 196 | `LD_PRELOAD=/tmp/sd/yi-hack/lib/ipc_multiplex.so ./dispatch &` | required local IPC initialization; bootstrap owns startup |
| 206 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 208 | `chmod 777 /tmp/sd/debug.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 209 | `sh /tmp/sd/debug.sh &` | obsolete/unneeded launch hook for local operation; omitted |
| 211 | `echo "rmmod not used wifi module"` | required network initialization; unused alternatives omitted |
| 220 | `wifi_module_state=$(cat /sys/class/misc/sunxi-wlan/rf-ctrl/sdio_wifi_name)` | required network initialization; unused alternatives omitted |
| 221 | `echo "wifi_module_state=$wifi_module_state"` | required network initialization; unused alternatives omitted |
| 222 | `if [ "$wifi_module_state" == "2" ]; then` | required network initialization; unused alternatives omitted |
| 223 | `echo "rmmod $sdio_wifi_ssv6158.ko"` | required network initialization; unused alternatives omitted |
| 224 | `rmmod $sdio_wifi_ssv6158` | required network initialization; unused alternatives omitted |
| 225 | `elif [ "$wifi_module_state" == "3" ]; then` | required network initialization; unused alternatives omitted |
| 226 | `echo "rmmod $sdio_wifi_ssv6158.ko"` | required network initialization; unused alternatives omitted |
| 227 | `rmmod $sdio_wifi_ssv6158` | required network initialization; unused alternatives omitted |
| 228 | `echo "rmmod $sdio_wifi_8189fs.ko"` | required network initialization; unused alternatives omitted |
| 229 | `rmmod $sdio_wifi_8189fs` | required network initialization; unused alternatives omitted |
| 230 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 232 | `echo "============================================= end home low_half_init.sh... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 234 | `chmod 755 /tmp/sd/yi-hack/script/system.sh` | required local services initialization; guarded handoff |
| 235 | `sh /tmp/sd/yi-hack/script/system.sh &` | required local services initialization; guarded handoff |

## y28ga: /backup/lower_half_init.sh

SHA256: `42351a4cc58f16dd7761fa98e0b0bfb2886b75e84b186730ee355ac60e3c778a`.

| Line | Operation | Classification / disposition |
|---:|---|---|
| 4 | `if [ -f /home/base/wifi/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 5 | `insmod /home/base/wifi/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 6 | `elif [ -f /home/base/wifi/8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 7 | `insmod /home/base/wifi/8189fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 8 | `elif [ -f /backup/ko/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 9 | `insmod /backup/ko/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 10 | `elif [ -f /backup/ko/8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 11 | `insmod /backup/ko/8189fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 12 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 14 | `echo "--------------------------insmod sensor--------------------------"` | required hardware/kernel initialization; only observed modules retained |
| 15 | `insmod /home/base/ko/videobuf2-core.ko` | required hardware/kernel initialization; only observed modules retained |
| 16 | `insmod /home/base/ko/videobuf2-memops.ko` | required hardware/kernel initialization; only observed modules retained |
| 17 | `insmod /home/base/ko/videobuf2-dma-contig.ko` | required hardware/kernel initialization; only observed modules retained |
| 18 | `insmod /home/base/ko/videobuf2-v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 19 | `insmod /home/base/ko/vin_io.ko` | required hardware/kernel initialization; only observed modules retained |
| 20 | `insmod /home/base/ko/cam_sensor.ko` | required hardware/kernel initialization; only observed modules retained |
| 21 | `insmod /home/base/ko/vin_v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 23 | `if [ -f /home/base/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 24 | `insmod /home/base/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 25 | `elif [ -f /backup/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 26 | `insmod /backup/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 27 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 29 | `if [ -f /home/base/ko/sunxi_gpadc.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 30 | `insmod /home/base/ko/sunxi_gpadc.ko` | required hardware/kernel initialization; only observed modules retained |
| 31 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 37 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 38 | `ifconfig lo up` | required network initialization; unused alternatives omitted |
| 39 | `ifconfig wlan0 up` | required network initialization; unused alternatives omitted |
| 40 | `ethmac=d2:`ifconfig wlan0 &#124;grep HWaddr&#124;cut -d' ' -f10&#124;cut -d: -f2-`` | required network initialization; unused alternatives omitted |
| 41 | `ifconfig eth0 hw ether $ethmac` | required network initialization; unused alternatives omitted |
| 42 | `ifconfig eth0 up` | required network initialization; unused alternatives omitted |
| 44 | `echo "============================================= begin to start app... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 45 | `cd /home/app` | required rmm/media initialization |
| 46 | `if [ -f /home/app/property ];then` | obsolete/unneeded launch hook for local operation; omitted |
| 47 | `./property &` | obsolete/unneeded launch hook for local operation; omitted |
| 48 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 51 | `if [ -f "/tmp/sd/Factory/factory_test.sh" ]; then` | obsolete/unneeded launch hook for local operation; omitted |
| 52 | `/tmp/sd/Factory/config.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 53 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 54 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 56 | `./dispatch &` | required local IPC initialization; bootstrap owns startup |
| 57 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 58 | `./rmm &` | required rmm/media initialization; system.sh owns startup |
| 59 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 60 | `./mp4record &` | optional local feature: recording |
| 61 | `./cloud &` | Yi cloud; ablated |
| 62 | `./p2p_tnp &` | Yi P2P; ablated |
| 63 | `./oss &` | Yi upload/storage; ablated |
| 64 | `./watch_process &` | Yi cloud; ablated |

## y28ga: /home/app/lower_half_init.sh

SHA256: `5ddf880cd0588d2914739cf85521629d151a09c7183a9a0eb288cf41c33bd4d2`.

| Line | Operation | Classification / disposition |
|---:|---|---|
| 4 | `if [ "${enable_4g}" = "y" ];then` | obsolete/unneeded (stock control flow or logging) |
| 5 | `echo "4g is running...."` | obsolete/unneeded (stock control flow or logging) |
| 6 | `else` | obsolete/unneeded (stock control flow or logging) |
| 7 | `if [ -f /home/base/wifi/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 8 | `insmod /home/base/wifi/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 9 | `elif [ -f /home/base/wifi/8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 10 | `insmod /home/base/wifi/8188fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 11 | `elif [ -f /backup/ko/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 12 | `insmod /backup/ko/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 13 | `elif [ -f /backup/ko/8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 14 | `insmod /backup/ko/8189fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 15 | `elif [ -f /backup/ko/ssv6x5x.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 16 | `if [ -f /home/base/firmware/ssv6x5x/ssv6x5x-wifi.cfg ];then` | obsolete/unneeded (stock control flow or logging) |
| 17 | `insmod /backup/ko/ssv6x5x.ko stacfgpath="/home/base/firmware/ssv6x5x/ssv6x5x-wifi.cfg"` | required hardware/kernel initialization; only observed modules retained |
| 18 | `else` | obsolete/unneeded (stock control flow or logging) |
| 19 | `echo "not found ssv6x5x-wifi.cfg"` | obsolete/unneeded (stock control flow or logging) |
| 20 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 21 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 22 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 24 | `echo "--------------------------insmod sensor--------------------------"` | required hardware/kernel initialization; only observed modules retained |
| 25 | `insmod /home/base/ko/videobuf2-core.ko` | required hardware/kernel initialization; only observed modules retained |
| 26 | `insmod /home/base/ko/videobuf2-memops.ko` | required hardware/kernel initialization; only observed modules retained |
| 27 | `insmod /home/base/ko/videobuf2-dma-contig.ko` | required hardware/kernel initialization; only observed modules retained |
| 28 | `insmod /home/base/ko/videobuf2-v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 29 | `insmod /home/base/ko/vin_io.ko` | required hardware/kernel initialization; only observed modules retained |
| 30 | `insmod /home/base/ko/cam_sensor.ko` | required hardware/kernel initialization; only observed modules retained |
| 31 | `insmod /home/base/ko/vin_v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 33 | `if [ -f /home/base/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 34 | `insmod /home/base/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 35 | `elif [ -f /backup/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 36 | `insmod /backup/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 37 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 39 | `if [ -f /home/base/ko/sunxi_gpadc.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 40 | `insmod /home/base/ko/sunxi_gpadc.ko` | required hardware/kernel initialization; only observed modules retained |
| 41 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 48 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 49 | `ifconfig lo up` | required network initialization; unused alternatives omitted |
| 51 | `ifconfig ${NETWORK_IFACE} up` | required network initialization; unused alternatives omitted |
| 52 | `ethmac=d2:`ifconfig ${NETWORK_IFACE} &#124;grep HWaddr&#124;cut -d' ' -f10&#124;cut -d: -f2-`` | required network initialization; unused alternatives omitted |
| 61 | `ifconfig eth0 hw ether $ethmac` | required network initialization; unused alternatives omitted |
| 62 | `ifconfig eth0 up` | required network initialization; unused alternatives omitted |
| 64 | `echo "============================================= home low_half_init.sh... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 65 | `echo "============================================= begin to start app... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 66 | `cd /home/app` | required rmm/media initialization |
| 67 | `if [ -f /home/app/property ];then` | obsolete/unneeded launch hook for local operation; omitted |
| 68 | `./property &` | obsolete/unneeded launch hook for local operation; omitted |
| 69 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 72 | `if [ -f "/tmp/sd/Factory/factory_test.sh" ]; then` | obsolete/unneeded launch hook for local operation; omitted |
| 73 | `/tmp/sd/Factory/config.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 74 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 75 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 77 | `./dispatch &` | required local IPC initialization; bootstrap owns startup |
| 78 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 79 | `./rmm &` | required rmm/media initialization; system.sh owns startup |
| 80 | `sleep 2` | obsolete/unneeded (stock control flow or logging) |
| 81 | `./mp4record &` | optional local feature: recording |
| 82 | `./cloud &` | Yi cloud; ablated |
| 83 | `./p2p_tnp &` | Yi P2P; ablated |
| 84 | `./oss &` | Yi upload/storage; ablated |
| 85 | `./rtmp &` | Yi upload/storage; ablated |
| 86 | `./watch_process &` | Yi cloud; ablated |
| 88 | `chmod 777 /tmp/sd/debug.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 89 | `sh /tmp/sd/debug.sh &` | obsolete/unneeded launch hook for local operation; omitted |

## y28ga: /tmp/sd/lower_half_init.sh

SHA256: `fdc3f872b682c4693e9d2cddea52ddc3fe3e47c835b1302e5c3476aaf7adf917`.

| Line | Operation | Classification / disposition |
|---:|---|---|
| 4 | `if [ -f /tmp/init_started ]; then` | obsolete/unneeded (stock control flow or logging) |
| 5 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 6 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 8 | `touch /tmp/init_started` | obsolete/unneeded (stock control flow or logging) |
| 11 | `if [ "${enable_4g}" = "y" ];then` | obsolete/unneeded (stock control flow or logging) |
| 12 | `echo "4g is running...."` | obsolete/unneeded (stock control flow or logging) |
| 13 | `else` | obsolete/unneeded (stock control flow or logging) |
| 14 | `if [ -f /home/base/wifi/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 15 | `insmod /home/base/wifi/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 16 | `elif [ -f /home/base/wifi/8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 17 | `insmod /home/base/wifi/8188fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 18 | `elif [ -f /backup/ko/8188fu.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 19 | `insmod /backup/ko/8188fu.ko` | required hardware/kernel initialization; only observed modules retained |
| 20 | `elif [ -f /backup/ko/8189fs.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 21 | `insmod /backup/ko/8189fs.ko` | required hardware/kernel initialization; only observed modules retained |
| 22 | `elif [ -f /backup/ko/atbm603x_wifi_usb.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 23 | `insmod /backup/ko/atbm603x_wifi_usb.ko` | required hardware/kernel initialization; only observed modules retained |
| 24 | `elif [ -f /backup/ko/ssv6x5x.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 25 | `if [ -f /home/base/firmware/ssv6x5x/ssv6x5x-wifi.cfg ];then` | obsolete/unneeded (stock control flow or logging) |
| 26 | `insmod /backup/ko/ssv6x5x.ko stacfgpath="/home/base/firmware/ssv6x5x/ssv6x5x-wifi.cfg"` | required hardware/kernel initialization; only observed modules retained |
| 27 | `else` | obsolete/unneeded (stock control flow or logging) |
| 28 | `echo "not found ssv6x5x-wifi.cfg"` | obsolete/unneeded (stock control flow or logging) |
| 29 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 30 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 31 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 33 | `echo "--------------------------insmod sensor--------------------------"` | required hardware/kernel initialization; only observed modules retained |
| 34 | `insmod /home/base/ko/videobuf2-core.ko` | required hardware/kernel initialization; only observed modules retained |
| 35 | `insmod /home/base/ko/videobuf2-memops.ko` | required hardware/kernel initialization; only observed modules retained |
| 36 | `insmod /home/base/ko/videobuf2-dma-contig.ko` | required hardware/kernel initialization; only observed modules retained |
| 37 | `insmod /home/base/ko/videobuf2-v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 38 | `insmod /home/base/ko/vin_io.ko` | required hardware/kernel initialization; only observed modules retained |
| 39 | `insmod /home/base/ko/cam_sensor.ko` | required hardware/kernel initialization; only observed modules retained |
| 40 | `insmod /home/base/ko/vin_v4l2.ko` | required hardware/kernel initialization; only observed modules retained |
| 42 | `if [ -f /home/base/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 43 | `insmod /home/base/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 44 | `elif [ -f /backup/ko/icplus.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 45 | `insmod /backup/ko/icplus.ko` | required hardware/kernel initialization; only observed modules retained |
| 46 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 48 | `if [ -f /home/base/ko/sunxi_gpadc.ko ];then` | obsolete/unneeded (stock control flow or logging) |
| 49 | `insmod /home/base/ko/sunxi_gpadc.ko` | required hardware/kernel initialization; only observed modules retained |
| 50 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 57 | `sleep 1` | obsolete/unneeded (stock control flow or logging) |
| 58 | `ifconfig lo up` | required network initialization; unused alternatives omitted |
| 60 | `ifconfig ${NETWORK_IFACE} up` | required network initialization; unused alternatives omitted |
| 61 | `ethmac=d2:`ifconfig ${NETWORK_IFACE} &#124;grep HWaddr&#124;cut -d' ' -f10&#124;cut -d: -f2-`` | required network initialization; unused alternatives omitted |
| 70 | `ifconfig eth0 hw ether $ethmac` | required network initialization; unused alternatives omitted |
| 71 | `ifconfig eth0 up` | required network initialization; unused alternatives omitted |
| 73 | `HOMEVER=$(cat /home/homever)` | obsolete/unneeded (stock control flow or logging) |
| 74 | `HV=${HOMEVER:0:2}` | obsolete/unneeded (stock control flow or logging) |
| 76 | `if [ "$HV" == "11" ] &#124;&#124; [ "$HV" == "12" ]; then` | obsolete/unneeded (stock control flow or logging) |
| 77 | `ln -s /home/model/BodyVehicleAnimal3.model /tmp/BodyVehicleAnimal3.model` | obsolete/unneeded: disabled AI pipeline model link |
| 78 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 80 | `echo "============================================= home low_half_init.sh... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 81 | `echo "============================================= begin to start app... ========================================="` | obsolete/unneeded (stock control flow or logging) |
| 82 | `cd /home/app` | required rmm/media initialization |
| 83 | `if [ -f /home/app/property ];then` | obsolete/unneeded launch hook for local operation; omitted |
| 84 | `./property &` | obsolete/unneeded launch hook for local operation; omitted |
| 85 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 88 | `if [ -f "/tmp/sd/Factory/factory_test.sh" ]; then` | obsolete/unneeded launch hook for local operation; omitted |
| 89 | `/tmp/sd/Factory/config.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 90 | `exit` | obsolete/unneeded (stock control flow or logging) |
| 91 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 95 | `export LD_LIBRARY_PATH=/home/app/locallib:/home/app/script:$LD_LIBRARY_PATH:/tmp` | required rmm/media initialization |
| 96 | `echo $LD_LIBRARY_PATH` | required rmm/media initialization |
| 98 | `if [ "$HV" == "11" ] &#124;&#124; [ "$HV" == "12" ]; then` | obsolete/unneeded (stock control flow or logging) |
| 99 | `if [ -f "/tmp/sd/log_tools.tar.gz" ];then` | Yi telemetry/diagnostic launch hook; omitted |
| 100 | `echo "run log_tools start."` | Yi telemetry/diagnostic launch hook; omitted |
| 101 | `if [ ! -d /tmp/sd/log_tools ];then` | Yi telemetry/diagnostic launch hook; omitted |
| 102 | `cd /tmp/sd` | obsolete/unneeded (stock control flow or logging) |
| 103 | `mkdir log_tools` | Yi telemetry/diagnostic launch hook; omitted |
| 104 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 105 | `cd /tmp/sd` | obsolete/unneeded (stock control flow or logging) |
| 106 | `tar -zxvf log_tools.tar.gz -C /tmp/sd/log_tools` | Yi telemetry/diagnostic launch hook; omitted |
| 107 | `chmod +x /tmp/sd/log_tools/run_log_app.sh` | Yi telemetry/diagnostic launch hook; omitted |
| 108 | `source /tmp/sd/log_tools/run_log_app.sh` | Yi telemetry/diagnostic launch hook; omitted |
| 109 | `cd -` | obsolete/unneeded (stock control flow or logging) |
| 110 | `echo "run log_tools end."` | Yi telemetry/diagnostic launch hook; omitted |
| 112 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 113 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 115 | `mount --bind /tmp/sd/yi-hack/script/wifidhcp.sh /home/app/script/wifidhcp.sh` | required network initialization; bind checked for failure |
| 116 | `mount --bind /tmp/sd/yi-hack/script/wifidhcp.sh /backup/tools/wifidhcp.sh` | required network initialization; bind checked for failure |
| 117 | `mount --bind /tmp/sd/yi-hack/script/ethdhcp.sh /home/app/script/ethdhcp.sh` | required network initialization; bind checked for failure |
| 118 | `mount --bind /tmp/sd/yi-hack/script/ethdhcp.sh /backup/tools/ethdhcp.sh` | required network initialization; bind checked for failure |
| 120 | `LD_PRELOAD=/tmp/sd/yi-hack/lib/ipc_multiplex.so ./dispatch &` | required local IPC initialization; bootstrap owns startup |
| 131 | `chmod 777 /tmp/sd/debug.sh` | obsolete/unneeded launch hook for local operation; omitted |
| 132 | `if [ -f "/tmp/sd/debug.sh" ]; then` | obsolete/unneeded launch hook for local operation; omitted |
| 133 | `echo "calling /tmp/sd/debug.sh"` | obsolete/unneeded launch hook for local operation; omitted |
| 134 | `sh /tmp/sd/debug.sh &` | obsolete/unneeded launch hook for local operation; omitted |
| 135 | `fi` | obsolete/unneeded (stock control flow or logging) |
| 137 | `chmod 755 /tmp/sd/yi-hack/script/system.sh` | required local services initialization; guarded handoff |
| 138 | `sh /tmp/sd/yi-hack/script/system.sh &` | required local services initialization; guarded handoff |
