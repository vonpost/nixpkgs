/* Build configuration used to build glibc, Info files, and locale
   information.

   Note that this derivation has multiple outputs and does not respect the
   standard convention of putting the executables into the first output. The
   first output is `lib` so that the libraries provided by this derivation
   can be accessed directly, e.g.

     "${pkgs.glibc}/lib/ld-linux-x86_64.so.2"

   The executables are put into `bin` output and need to be referenced via
   the `bin` attribute of the main package, e.g.

     "${pkgs.glibc.bin}/bin/ldd".

  The executables provided by glibc typically include `ldd`, `locale`, `iconv`
  but the exact set depends on the library version and the configuration.
*/

{ stdenv, lib
, buildPackages
, fetchurl ? null
, linuxHeaders ? null
, gd ? null, libpng ? null
, bison
}:

{ name
, withLinuxHeaders ? false
, profilingLibraries ? false
, installLocales ? false
, withGd ? false
, meta
, ...
} @ args:

let
  version = "2.23";
  patchSuffix = "";
  sha256 = "94efeb00e4603c8546209cefb3e1a50a5315c86fa9b078b6fad758e187ce13e9";

in

assert withLinuxHeaders -> linuxHeaders != null;
assert withGd -> gd != null && libpng != null;

stdenv.mkDerivation ({
  inherit version installLocales;
  linuxHeaders = if withLinuxHeaders then linuxHeaders else null;

  inherit (stdenv) is64bit;

  enableParallelBuilding = true;
  patches =
    [ /* Have rpcgen(1) look for cpp(1) in $PATH.  */
      ./rpcgen-path.patch

      /* Allow NixOS and Nix to handle the locale-archive. */
      ./nix-locale-archive.patch

      /* Don't use /etc/ld.so.cache, for non-NixOS systems.  */
      ./dont-use-system-ld-so-cache.patch

      /* Don't use /etc/ld.so.preload, but /etc/ld-nix.so.preload.  */
      ./dont-use-system-ld-so-preload.patch

      /* Add blowfish password hashing support.  This is needed for
         compatibility with old NixOS installations (since NixOS used
         to default to blowfish). */
      ./glibc-crypt-blowfish.patch

      /* The command "getconf CS_PATH" returns the default search path
         "/bin:/usr/bin", which is inappropriate on NixOS machines. This
         patch extends the search path by "/run/current-system/sw/bin". */
      ./fix_path_attribute_in_getconf.patch

      ./cve-2016-3075.patch
      ./glob-simplify-interface.patch
      ./cve-2016-1234.patch
      ./cve-2016-3706.patch
      ./fix_warnings.patch
      ./locwrongaddress.patch
      ./epow_boolean_comparison.patch
    ];

  postPatch =
    # Needed for glibc to build with the gnumake 3.82
    # http://comments.gmane.org/gmane.linux.lfs.support/31227
    ''
      sed -i 's/ot \$/ot:\n\ttouch $@\n$/' manual/Makefile
    ''
    # nscd needs libgcc, and we don't want it dynamically linked
    # because we don't want it to depend on bootstrap-tools libs.
    + ''
      echo "LDFLAGS-nscd += -static-libgcc" >> nscd/Makefile
    ''
    # Replace the date and time in nscd by a prefix of $out.
    # It is used as a protocol compatibility check.
    # Note: the size of the struct changes, but using only a part
    # would break hash-rewriting. When receiving stats it does check
    # that the struct sizes match and can't cause overflow or something.
    + ''
      cat ${./glibc-remove-datetime-from-nscd.patch} \
        | sed "s,@out@,$out," | patch -p1
    ''
    # CVE-2014-8121, see https://bugzilla.redhat.com/show_bug.cgi?id=1165192
    + ''
      substituteInPlace ./nss/nss_files/files-XXX.c \
        --replace 'status = internal_setent (stayopen);' \
                  'status = internal_setent (1);'
    '';


  configureFlags =
    [ "-C"
      "--disable-werror"
      "--enable-add-ons"
      "--enable-obsolete-nsl"
      "--enable-obsolete-rpc"
      "--sysconfdir=/etc"
      "--enable-stackguard-randomization"
      (lib.withFeatureAs withLinuxHeaders "headers" "${linuxHeaders}/include")
      (lib.enableFeature profilingLibraries "profile")
    ] ++ lib.optionals withLinuxHeaders [
      "--enable-kernel=3.2.0" # can't get below with glibc >= 2.26
    ] ++ lib.optionals (stdenv.hostPlatform != stdenv.buildPlatform) [
      (lib.flip lib.withFeature "fp"
         (stdenv.hostPlatform.platform.gcc.float or (stdenv.hostPlatform.parsed.abi.float or "hard") == "soft"))
      "--with-__thread"
    ] ++ lib.optionals (stdenv.hostPlatform == stdenv.buildPlatform && stdenv.hostPlatform.isAarch32) [
      "--host=arm-linux-gnueabi"
      "--build=arm-linux-gnueabi"

      # To avoid linking with -lgcc_s (dynamic link)
      # so the glibc does not depend on its compiler store path
      "libc_cv_as_needed=no"
    ] ++ lib.optional withGd "--with-gd";

  installFlags = [ "sysconfdir=$(out)/etc" ];

  outputs = [ "out" "bin" "dev" "static" ];

  depsBuildBuild = [ buildPackages.stdenv.cc ];
  nativeBuildInputs = [ bison ];
  buildInputs = [ linuxHeaders ] ++ lib.optionals withGd [ gd libpng ];

  # Needed to install share/zoneinfo/zone.tab.  Set to impure /bin/sh to
  # prevent a retained dependency on the bootstrap tools in the stdenv-linux
  # bootstrap.
  BASH_SHELL = "/bin/sh";

  passthru = { inherit version; };
}

// (removeAttrs args [ "withLinuxHeaders" "withGd" ]) //

{
  name = name + "-${version}${patchSuffix}";

  src = fetchurl {
    url = "mirror://gnu/glibc/glibc-${version}.tar.xz";
    inherit sha256;
  };

  # Remove absolute paths from `configure' & co.; build out-of-tree.
  preConfigure = ''
    export PWD_P=$(type -tP pwd)
    for i in configure io/ftwtest-sh; do
        # Can't use substituteInPlace here because replace hasn't been
        # built yet in the bootstrap.
        sed -i "$i" -e "s^/bin/pwd^$PWD_P^g"
    done

    mkdir ../build
    cd ../build

    configureScript="`pwd`/../$sourceRoot/configure"

    ${lib.optionalString (stdenv.cc.libc != null)
      ''makeFlags="$makeFlags BUILD_LDFLAGS=-Wl,-rpath,${stdenv.cc.libc}/lib"''
    }


  '' + lib.optionalString (stdenv.hostPlatform != stdenv.buildPlatform) ''
    sed -i s/-lgcc_eh//g "../$sourceRoot/Makeconfig"

    cat > config.cache << "EOF"
    libc_cv_forced_unwind=yes
    libc_cv_c_cleanup=yes
    libc_cv_gnu89_inline=yes
    EOF
  '';

  preBuild = lib.optionalString withGd "unset NIX_DONT_SET_RPATH";

  doCheck = false; # fails

  meta = {
    homepage = https://www.gnu.org/software/libc/;
    description = "The GNU C Library";

    longDescription =
      '' Any Unix-like operating system needs a C library: the library which
         defines the "system calls" and other basic facilities such as
         open, malloc, printf, exit...

         The GNU C library is used as the C library in the GNU system and
         most systems with the Linux kernel.
      '';

    license = lib.licenses.lgpl2Plus;

    maintainers = [ lib.maintainers.eelco ];
    platforms = lib.platforms.linux;
  } // meta;
}

// lib.optionalAttrs (stdenv.hostPlatform != stdenv.buildPlatform) {
  preInstall = null; # clobber the native hook

  dontStrip = true;

  separateDebugInfo = false; # this is currently broken for crossDrv

  # To avoid a dependency on the build system 'bash'.
  preFixup = ''
    rm -f $bin/bin/{ldd,tzselect,catchsegv,xtrace}
  '';
})
