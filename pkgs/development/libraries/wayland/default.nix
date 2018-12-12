{ lib, stdenv, fetchurl, pkgconfig, buildPackages, hostPlatform, buildPlatform
, libffi, libxml2
, expat ? null # Build wayland-scanner (currently cannot be disabled as of 1.7.0)
}:

# Require the optional to be enabled until upstream fixes or removes the configure flag
assert expat != null;

stdenv.mkDerivation rec {
  name = "wayland-${version}";
  version = "1.16.0";
 
  src = fetchurl {
    url = "https://wayland.freedesktop.org/releases/${name}.tar.xz";
    sha256 = "1xajhxad43izq9f7sbww1hlg42nayijy8xnp21kgpk09c6sw4wjf";
  };

configureFlags = [ "--disable-documentation" ] ++ lib.optional (hostPlatform != buildPlatform) "--with-host-scanner";
  depsBuildBuild = [] ++ lib.optional ( hostPlatform != buildPlatform ) buildPackages.wayland;
  nativeBuildInputs = [ pkgconfig ];

  buildInputs = [ libffi /* docbook_xsl doxygen graphviz libxslt xmlto */ expat libxml2 ];

  meta = {
    description = "Reference implementation of the wayland protocol";
    homepage    = https://wayland.freedesktop.org/;
    license     = lib.licenses.mit;
    platforms   = lib.platforms.linux;
    maintainers = with lib.maintainers; [ codyopel wkennington ];
  };

  passthru.version = version;
}
