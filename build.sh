#!/bin/bash

# build: tmp build files
# output: final files only, for distribution
rm -rf build output
mkdir build output
mkdir output/static output/dynamic


if [ -z "$1" ]; then
	echo "Please copy sample.config.in to your.config, configure it, and then launch this script as ./build.sh your.config"
	exit 1
fi

source $1

if [ -z "$RELEASE" ] || [ -z "$PKG_URL_PREFIX" ] || [ -z "$STAGE2_URL_BASE" ] || [ -z "$SHELL_VERSION" ] || [ -z "$TAIHEN_VERSION" ] || [ -z "$TAIHEN_CRC32" ] || [ -z "$HENKAKU_RELEASE" ]; then
	echo "Please make sure all of the following variables are defined in your config file:"
	echo "RELEASE, PKG_URL_PREFIX, STAGE2_URL_BASE, SHELL_VERSION, TAIHEN_VERSION, TAIHEN_CRC32, HENKAKU_RELEASE"
	echo "(see sample.config.in for an example)"
	exit 2
fi

if [ -z "$BETA_RELEASE" ]; then
  BETA_RELEASE=0
fi

set -ex

CC=arm-vita-eabi-gcc
LD=arm-vita-eabi-gcc
AS=arm-vita-eabi-as
OBJCOPY=arm-vita-eabi-objcopy
LDFLAGS="-T payload/linker.x -nodefaultlibs -nostdlib -pie"
DEFINES="-DRELEASE=$RELEASE"
PREPROCESS="$CC -E -P -C -w -x c $DEFINES"
CFLAGS="-fPIE -fno-zero-initialized-in-bss -std=c99 -mcpu=cortex-a9 -Os -mthumb $DEFINES"

# generate version stuffs
BUILD_VERSION=$(git describe --dirty --always --tags)
BUILD_DATE=$(date)
BUILD_HOST=$(hostname)
echo "#define BUILD_VERSION \"$BUILD_VERSION\"" >> build/version.c
echo "#define BUILD_DATE \"$BUILD_DATE\"" >> build/version.c
echo "#define BUILD_HOST \"$BUILD_HOST\"" >> build/version.c
echo "#define SHELL_VERSION $SHELL_VERSION" >> build/version.c
echo "#define HENKAKU_RELEASE $HENKAKU_RELEASE" >> build/version.c
echo "#define BETA_RELEASE $BETA_RELEASE" >> build/version.c
echo "#define TAIHEN_VERSION $TAIHEN_VERSION" >> build/version.c
echo "#define TAIHEN_CRC32 $TAIHEN_CRC32" >> build/version.c

echo "0) taiHEN plugin"

mkdir build/plugin
pushd build/plugin
cmake -DRELEASE=$RELEASE ../../plugin
make
popd
cp build/plugin/henkaku.skprx output/henkaku.skprx
cp build/plugin/henkaku.suprx output/henkaku.suprx
HENKAKU_CRC32=$(crc32 output/henkaku.skprx)
HENKAKU_USER_CRC32=$(crc32 output/henkaku.suprx)

echo "1) User payload"

echo "#define HENKAKU_CRC32 0x$HENKAKU_CRC32" >> build/version.c
echo "#define HENKAKU_USER_CRC32 0x$HENKAKU_USER_CRC32" >> build/version.c

PAYLOAD_KEY=c787069478255b5051727bc3fdecff1a

# user payload is injected into web browser process
$CC -c -o build/user.o payload/user/user.c $CFLAGS
$CC -c -o build/compress.o payload/user/compress.c $CFLAGS
$CC -c -o build/crc32.o payload/user/crc32.c $CFLAGS
$LD -o build/user.elf build/user.o build/compress.o build/crc32.o -lgcc $LDFLAGS
$OBJCOPY -O binary build/user.elf build/user.bin
xxd -i build/user.bin > build/user.h

echo "2) Payload"

# loader decrypts and lods a larger payload
$CC -c -o build/loader.o payload/loader.c $CFLAGS
$AS -o build/loader_start.o payload/loader_start.S
$LD -o build/loader.elf build/loader.o build/loader_start.o $LDFLAGS
$OBJCOPY -O binary build/loader.elf build/loader.bin

$CC -c -o build/payload.o payload/payload.c $CFLAGS
$LD -o build/payload.elf build/payload.o $LDFLAGS
$OBJCOPY -O binary build/payload.elf build/payload.bin

cat payload/pad.bin build/loader.bin > build/loader.full
# loader must be <=0x100 bytes
SIZE=$(ls -l build/loader.full | awk '{ print $5 }')
if ((SIZE>0x100)); then
	echo "loader size is $SIZE should be less or equal 0x100 bytes"
	exit -1
fi
echo "loader size is $SIZE"
dd if=/dev/zero bs=256 count=1 > build/loader.256
dd of=build/loader.256 if=build/loader.full bs=256 count=1 conv=notrunc
openssl enc -aes-256-ecb -in build/loader.256 -nopad -out build/loader.enc -K BD00BF08B543681B6B984708BD00BF0023036018467047D0F8A03043F69D1130
openssl enc -aes-128-ecb -in build/payload.bin -nopad -out build/payload.enc -K $PAYLOAD_KEY

./payload/block_check.py build/loader.enc
./payload/block_check.py build/payload.enc

./payload/write_pkg_url.py build/payload.enc $PKG_URL_PREFIX

echo "3) Kernel ROP"
if [ "x$KROP_PREBUILT" == "x" ]; then
  ./krop/build_rop.py krop/rop.S build/
else
  echo "using prebuilt krop"
  cp $KROP_PREBUILT build/krop.rop
fi

echo "4) User ROP"
echo "symbol stage2_url_base = \"$STAGE2_URL_BASE\";" > build/config.rop

./urop/make_rop_array.py build/loader.enc kx_loader build/kx_loader.rop
./urop/make_rop_array.py build/payload.enc second_payload build/second_payload.rop

$PREPROCESS urop/exploit.rop.in -o build/exploit.rop.in
erb build/exploit.rop.in > build/exploit.rop
roptool -s build/exploit.rop -t urop/webkit-360-pkg -o build/exploit.rop.bin >/dev/null

$PREPROCESS urop/loader.rop.in -o build/loader.rop.in
erb build/loader.rop.in > build/loader.rop
roptool -s build/loader.rop -t urop/webkit-360-pkg -o build/loader.rop.bin >/dev/null

echo "5) Webkit"
# Static website
$PREPROCESS webkit/exploit.js -DSTATIC=1 -o build/exploit.static.js
uglifyjs build/exploit.static.js -m "toplevel" > build/exploit.js
touch output/static/exploit.html
printf "<script>" >> output/static/exploit.html
cat build/exploit.js >> output/static/exploit.html
printf "</script>" >> output/static/exploit.html
./webkit/preprocess.py build/exploit.rop.bin output/static/payload.bin

# Dynamic website
$PREPROCESS webkit/exploit.js -DSTATIC=0 -o build/exploit.dynamic.js
uglifyjs build/exploit.dynamic.js -m "toplevel" > build/exploit.js
touch output/dynamic/exploit.html
printf "<noscript>Go to browser settings and check \"Enable JavaScript\", then reload this page.</noscript><script src='payload.js'></script><script>" >> output/dynamic/exploit.html
cat build/exploit.js >> output/dynamic/exploit.html
printf "</script>" >> output/dynamic/exploit.html
cp output/static/payload.bin output/dynamic/stage2.bin
./webkit/preprocess.py build/loader.rop.bin output/dynamic/payload.js
cp webkit/stage2.php output/dynamic/stage2.php
cp webkit/stage2.go output/dynamic/stage2.go

echo "6) Offline"
mkdir -p build/offline output/offline

# offline user-mode is different
$CC -c -o build/offline/user.o payload/user/user.c $CFLAGS -DOFFLINE=1
$LD -o build/offline/user.elf build/offline/user.o build/compress.o build/crc32.o -lgcc $LDFLAGS
$OBJCOPY -O binary build/offline/user.elf build/offline/user.bin
xxd -i build/offline/user.bin > build/offline/user.h

# offline kernel payload is different
$CC -c -o build/offline/payload.o payload/payload.c $CFLAGS -DOFFLINE=1
$LD -o build/offline/payload.elf build/offline/payload.o $LDFLAGS
$OBJCOPY -O binary build/offline/payload.elf build/offline/payload.bin
openssl enc -aes-128-ecb -in build/offline/payload.bin -nopad -out build/offline/payload.enc -K $PAYLOAD_KEY
./urop/make_rop_array.py build/offline/payload.enc second_payload build/offline/second_payload.rop

# as a result, offline urop exploit is different as well
# prepare offline stage2
$PREPROCESS urop/exploit.rop.in -o build/offline/exploit.rop.in -DOFFLINE=1
erb build/offline/exploit.rop.in > build/offline/exploit.rop
roptool -s build/offline/exploit.rop -t urop/webkit-360-pkg -o build/offline/exploit.rop.bin >/dev/null
./webkit/preprocess.py build/offline/exploit.rop.bin build/offline/stage2.bin

./urop/offline_stage2.py build/offline/stage2.bin build/offline/henkaku.bin build/offline/size.rop
cp build/offline/henkaku.bin output/offline/

# offline rop loader
$PREPROCESS urop/offline_loader.rop.in -o build/offline/loader.rop.in
erb build/offline/loader.rop.in > build/offline/loader.rop
roptool -s build/offline/loader.rop -t urop/webkit-360-pkg -o build/offline/loader.rop.bin -v

./webkit/preprocess.py build/offline/loader.rop.bin build/offline/loader.js

# offline exploit (has -DOFFLINE to disable alerts)
$PREPROCESS webkit/exploit.js -DSTATIC=0 -DOFFLINE=1 -o build/offline/exploit.js
uglifyjs build/offline/exploit.js -m "toplevel" > build/offline/exploit.min.js

# offline stage1 exploit and payload in a single html to load from email app
touch output/offline/exploit.html
printf "<html><body><script>" >> output/offline/exploit.html
cat build/offline/loader.js >> output/offline/exploit.html
cat build/offline/exploit.min.js >> output/offline/exploit.html
printf "</script></body></html>" >> output/offline/exploit.html
