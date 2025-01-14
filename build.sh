#!/usr/bin/env bash

set -e # exit if a command fails
set -o pipefail # Will return the exit status of make if it fails
set -o physical # Resolve symlinks when changing directory

project_source_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

package_windows() {
    rm -rf dist
    mkdir -p dist
    cp build/qemu-system-i386.exe dist/xemu.exe
    cp build/qemu-system-i386w.exe dist/xemuw.exe
    cp -r "${project_source_dir}/data" dist/
    python3 "${project_source_dir}/get_deps.py" dist/xemu.exe dist
    strip dist/xemu.exe
    strip dist/xemuw.exe
}

package_wincross() {
    STRIP=${CROSSPREFIX}strip
    rm -rf dist
    mkdir -p dist
    cp build/qemu-system-i386.exe dist/xemu.exe
    cp build/qemu-system-i386w.exe dist/xemuw.exe
    cp -r "${project_source_dir}/data" dist/
    $STRIP dist/xemu.exe
    $STRIP dist/xemuw.exe
}

package_macos() {
    #
    # Create bundle
    #
    rm -rf dist

    # Copy in executable
    mkdir -p dist/xemu.app/Contents/MacOS/
    cp build/qemu-system-i386 dist/xemu.app/Contents/MacOS/xemu

    # Copy in in executable dylib dependencies
    mkdir -p dist/xemu.app/Contents/Frameworks
    dylibbundler -cd -of -b -x dist/xemu.app/Contents/MacOS/xemu \
        -d dist/xemu.app/Contents/Frameworks/ \
        -p '@executable_path/../Frameworks/'

    # Copy in runtime resources
    mkdir -p dist/xemu.app/Contents/Resources
    cp -r "${project_source_dir}/data" dist/xemu.app/Contents/Resources

    # Generate icon file
    mkdir -p xemu.iconset
    for r in 16 32 128 256 512; do cp "${project_source_dir}/ui/icons/xemu_${r}x${r}.png" "xemu.iconset/icon_${r}x${r}.png"; done
    iconutil --convert icns --output dist/xemu.app/Contents/Resources/xemu.icns xemu.iconset

    # Generate Info.plist file
    cat <<EOF > dist/xemu.app/Contents/Info.plist
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleExecutable</key>
  <string>xemu</string>
  <key>CFBundleIconFile</key>
  <string>xemu.icns</string>
  <key>CFBundleIdentifier</key>
  <string>xemu.app.0</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>xemu</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>1</string>
  <key>CFBundleSignature</key>
  <string>xemu</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.games</string>
  <key>LSMinimumSystemVersion</key>
  <string>10.6</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
EOF
}

package_linux() {
    rm -rf dist
    mkdir -p dist
    cp build/qemu-system-i386 dist/xemu
    cp -r "${project_source_dir}/data" dist
}

postbuild=''
debug_opts=''
build_cflags='-O3'
default_job_count='12'
sys_ldflags=''

get_job_count () {
	if command -v 'nproc' >/dev/null
	then
		nproc
	else
		case "$(uname -s)" in
			'Linux')
				egrep "^processor" /proc/cpuinfo | wc -l
				;;
			'FreeBSD')
				sysctl -n hw.ncpu
				;;
			'Darwin')
				sysctl -n hw.logicalcpu 2>/dev/null \
				|| sysctl -n hw.ncpu
				;;
			'MSYS_NT-'*|'CYGWIN_NT-'*|'MINGW'*'_NT-'*)
				if command -v 'wmic' >/dev/null
				then
					wmic cpu get NumberOfLogicalProcessors/Format:List \
						| grep -m1 '=' | cut -f2 -d'='
				else
					echo "${NUMBER_OF_PROCESSORS:-${default_job_count}}"
				fi
				;;
			*)
				echo "${default_job_count}"
				;;
		esac
	fi
}

job_count="$(get_job_count)" 2>/dev/null
job_count="${job_count:-${default_job_count}}"
debug=""
opts=""
platform="$(uname -s)"

while [ ! -z "${1}" ]
do
    case "${1}" in
    '-j'*)
        job_count="${1:2}"
        shift
        ;;
    '--debug')
        debug="y"
        shift
        ;;
    '-p'*)
        platform="${2}"
        shift 2
        ;;
    *)
        break
        ;;
    esac
done

target="qemu-system-i386"
if test ! -z "$debug"; then
    build_cflags='-O0 -g -DXEMU_DEBUG_BUILD=1'
    opts="--enable-debug"
else
    opts="--enable-lto"
fi


case "$platform" in # Adjust compilation options based on platform
    Linux)
        echo 'Compiling for Linux...'
        sys_cflags='-Wno-error=redundant-decls'
        opts="$opts --disable-werror"
        postbuild='package_linux'
        ;;
    Darwin)
        echo 'Compiling for MacOS...'
        sys_cflags='-march=ivybridge'
        sys_ldflags='-headerpad_max_install_names'
        opts="$opts --disable-cocoa"
        # necessary to find libffi, which is required by gobject
        export PKG_CONFIG_PATH="${PKG_CONFIG_PATH}/usr/local/opt/libffi/lib/pkgconfig"
        export PKG_CONFIG_PATH="/usr/local/opt/openssl@1.1/lib/pkgconfig:${PKG_CONFIG_PATH}"
        echo $PKG_CONFIG_PATH
        postbuild='package_macos'
        ;;
    CYGWIN*|MINGW*|MSYS*)
        echo 'Compiling for Windows...'
        sys_cflags='-Wno-error'
        opts="$opts --disable-fortify-source"
        postbuild='package_windows' # set the above function to be called after build
        target="qemu-system-i386.exe qemu-system-i386w.exe"
        ;;
    win64-cross)
        echo 'Cross-compiling for Windows...'
        export AR=${AR:-$CROSSAR}
        sys_cflags='-Wno-error'
        opts="$opts --cross-prefix=$CROSSPREFIX --static --disable-fortify-source"
        postbuild='package_wincross' # set the above function to be called after build
        target="qemu-system-i386.exe qemu-system-i386w.exe"
        ;;
    *)
        echo "Unsupported platform $platform, aborting" >&2
        exit -1
        ;;
esac

# find absolute path (and resolve symlinks) to build out of tree
configure="${project_source_dir}/configure"
build_cflags="${build_cflags} -I${project_source_dir}/ui/imgui"

set -x # Print commands from now on

"${configure}" \
    --extra-cflags="-DXBOX=1 ${build_cflags} ${sys_cflags} ${CFLAGS}" \
    --extra-ldflags="${sys_ldflags}" \
    --target-list=i386-softmmu \
    ${opts} \
    "$@"

# Force imgui update now to work around annoying make issue
if ! test -f "${project_source_dir}/ui/imgui/imgui.cpp"; then
    ./scripts/git-submodule.sh update ui/imgui
fi

time make -j"${job_count}" ${target} 2>&1 | tee build.log

"${postbuild}" # call post build functions
